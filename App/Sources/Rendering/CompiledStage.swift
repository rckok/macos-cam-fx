import Foundation
import Metal

/// The reflected resources of one Metal function of a stage, with the
/// CPU-side `Params` buffer laid out to match its std140 block. Each function
/// has its own argument tables, so a geometry stage's vertex, fragment and
/// simulation functions are bound separately.
struct ShaderFunctionBindings {
    let file: ShaderFile
    let reflection: ShaderReflection
    /// Buffer backing this function's `Params` block; nil when it has none.
    let paramsBuffer: MTLBuffer?
    /// Metal constant-buffer lengths keyed by MSL buffer index. SPIR-V
    /// `get_declared_struct_size` omits trailing 16-byte padding that the
    /// Metal compiler adds, which otherwise fails validation (e.g. 88 vs 96).
    private let constantBufferLengths: [Int: Int]

    init(file: ShaderFile, reflection: ShaderReflection, device: MTLDevice, bindings: [any MTLBinding]) {
        self.file = file
        self.reflection = reflection
        var lengths: [Int: Int] = [:]
        for binding in bindings {
            guard let buffer = binding as? MTLBufferBinding, buffer.bufferDataSize > 0 else { continue }
            lengths[buffer.index] = buffer.bufferDataSize
        }
        self.constantBufferLengths = lengths

        if let block = reflection.paramsBlock, block.mslBuffer >= 0, block.size > 0 {
            let length = Self.constantBufferLength(spirvSize: block.size, metalSize: lengths[block.mslBuffer])
            self.paramsBuffer = device.makeBuffer(length: length, options: .storageModeShared)
        } else {
            self.paramsBuffer = nil
        }
    }

    /// Byte length Metal's compiler expects for this uniform block.
    func constantBufferLength(for block: ShaderReflection.UniformBlock) -> Int {
        Self.constantBufferLength(spirvSize: block.size, metalSize: constantBufferLengths[block.mslBuffer])
    }

    private static func constantBufferLength(spirvSize: Int, metalSize: Int?) -> Int {
        max(alignToConstantBuffer(spirvSize), metalSize ?? 0)
    }

    /// Metal constant structs are padded to 16 bytes; SPIR-V declared size is not.
    private static func alignToConstantBuffer(_ size: Int) -> Int {
        guard size > 0 else { return 0 }
        return (size + 15) & ~15
    }

    /// Writes a parameter value into the params buffer at its std140 offset.
    /// `values` are the scalar components (1 for float/int/bool, 2-4 for vectors).
    func writeParam(name: String, type: String, values: [Double]) {
        guard let paramsBuffer,
              let block = reflection.paramsBlock,
              let member = block.members.first(where: { $0.name == name })
        else { return }

        let base = paramsBuffer.contents().advanced(by: member.offset)
        switch type {
        case "float", "vec2", "vec3", "vec4":
            for (i, v) in values.enumerated() {
                base.advanced(by: i * 4).storeBytes(of: Float(v), as: Float.self)
            }
        case "int", "ivec2", "ivec3", "ivec4":
            for (i, v) in values.enumerated() {
                base.advanced(by: i * 4).storeBytes(of: Int32(v), as: Int32.self)
            }
        case "uint", "bool", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3", "bvec4":
            for (i, v) in values.enumerated() {
                base.advanced(by: i * 4).storeBytes(of: UInt32(v), as: UInt32.self)
            }
        default:
            break
        }
    }
}

/// A user stage compiled into Metal pipelines, plus the reflected resource
/// bindings of each function.
///
/// A fragment stage is one pipeline: the built-in fullscreen vertex function
/// and the user's fragment shader. A geometry stage draws with the user's
/// vertex and fragment shaders and, while its simulation pass is on, first
/// runs a fullscreen pipeline over its state textures.
final class CompiledStage {
    let kind: StageKind
    let pipeline: MTLRenderPipelineState
    /// Nil for fragment stages, which use the built-in fullscreen vertex function.
    let vertexBindings: ShaderFunctionBindings?
    let fragmentBindings: ShaderFunctionBindings
    let simulationPipeline: MTLRenderPipelineState?
    let simulationBindings: ShaderFunctionBindings?
    /// Slots the simulation pipeline writes; 0 without one.
    let stateSlots: Int
    /// Every file's reflection merged; see `ShaderReflection.merged`.
    let reflection: ShaderReflection
    /// Warnings from GLSL compile that did not fail the build.
    let warnings: [ShaderDiagnostic]
    /// Stage names used in `ceStageTexture("Name", ...)` calls, resolved to
    /// indices by the app whenever the owning effect's layout changes. Slots
    /// are shared by all of the stage's files.
    let stageReferences: [StageReference]

    /// Functions to bind before drawing, in the order they run.
    var drawBindings: [ShaderFunctionBindings] {
        [vertexBindings, fragmentBindings].compactMap { $0 }
    }

    private var allBindings: [ShaderFunctionBindings] {
        [simulationBindings, vertexBindings, fragmentBindings].compactMap { $0 }
    }

    /// Compiles every file `input` lists. All files are compiled even when one
    /// fails, so each tab shows its own errors.
    init(device: MTLDevice, fullscreenVertex: MTLFunction, input: StageCompileInput) throws {
        var jobs: [CompileJob] = []
        switch input.kind {
        case .fragment:
            jobs.append(CompileJob(file: .fragment, source: input.fragmentSource, prelude: .fullscreen))
        case .geometry:
            if let simulationSource = input.simulationSource {
                jobs.append(CompileJob(
                    file: .simulation,
                    source: simulationSource,
                    prelude: .simulation(stateSlots: input.stateSlots)
                ))
            }
            jobs.append(CompileJob(file: .vertex, source: input.vertexSource, prelude: .geometryVertex))
            jobs.append(CompileJob(file: .fragment, source: input.fragmentSource, prelude: .geometryFragment))
        }

        var outputs: [ShaderFile: ShaderCompileOutput] = [:]
        var references: [StageReference] = []
        var errors: [ShaderDiagnostic] = []
        for job in jobs {
            do {
                let output = try ShaderCompiler.compile(
                    userSource: job.source, prelude: job.prelude, file: job.file, references: references
                )
                outputs[job.file] = output
                references = output.stageReferences
            } catch let error as ShaderCompileError {
                errors.append(contentsOf: error.diagnostics)
            }
        }
        let compiledFiles = jobs.map(\.file).filter { outputs[$0] != nil }
        errors.append(contentsOf: Self.paramsConflicts(compiledFiles.compactMap { file in
            outputs[file].map { (file, $0.reflection) }
        }))
        guard errors.isEmpty, let fragmentOutput = outputs[.fragment] else {
            throw ShaderCompileError(diagnostics: errors)
        }

        self.kind = input.kind
        self.warnings = jobs.compactMap { outputs[$0.file] }.flatMap(\.diagnostics)
        self.stageReferences = references
        self.reflection = ShaderReflection.merged(jobs.compactMap { outputs[$0.file]?.reflection })

        let fragmentFunction = try Self.makeFunction(device: device, output: fragmentOutput, file: .fragment)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        if input.kind == .geometry, let vertexOutput = outputs[.vertex] {
            descriptor.vertexFunction = try Self.makeFunction(device: device, output: vertexOutput, file: .vertex)
            Self.configureBlending(descriptor.colorAttachments[0], blend: input.blend)
        } else {
            descriptor.vertexFunction = fullscreenVertex
        }

        var pipelineReflection: MTLAutoreleasedRenderPipelineReflection?
        self.pipeline = try Self.makePipeline(device: device, descriptor: descriptor, reflection: &pipelineReflection)
        self.fragmentBindings = ShaderFunctionBindings(
            file: .fragment,
            reflection: fragmentOutput.reflection,
            device: device,
            bindings: pipelineReflection?.fragmentBindings ?? []
        )
        if input.kind == .geometry, let vertexOutput = outputs[.vertex] {
            self.vertexBindings = ShaderFunctionBindings(
                file: .vertex,
                reflection: vertexOutput.reflection,
                device: device,
                bindings: pipelineReflection?.vertexBindings ?? []
            )
        } else {
            self.vertexBindings = nil
        }

        if let simulationOutput = outputs[.simulation] {
            let slots = input.stateSlots.clamped(to: GeometrySettings.stateSlotRange)
            let simulation = MTLRenderPipelineDescriptor()
            simulation.vertexFunction = fullscreenVertex
            simulation.fragmentFunction = try Self.makeFunction(device: device, output: simulationOutput, file: .simulation)
            for slot in 0..<slots {
                simulation.colorAttachments[slot].pixelFormat = .rgba32Float
            }
            var simulationReflection: MTLAutoreleasedRenderPipelineReflection?
            self.simulationPipeline = try Self.makePipeline(
                device: device, descriptor: simulation, reflection: &simulationReflection
            )
            self.simulationBindings = ShaderFunctionBindings(
                file: .simulation,
                reflection: simulationOutput.reflection,
                device: device,
                bindings: simulationReflection?.fragmentBindings ?? []
            )
            self.stateSlots = slots
        } else {
            self.simulationPipeline = nil
            self.simulationBindings = nil
            self.stateSlots = 0
        }
    }

    private struct CompileJob {
        let file: ShaderFile
        let source: String
        let prelude: ShaderPrelude
    }

    /// Writes a parameter into every function that declares it.
    func writeParam(name: String, type: String, values: [Double]) {
        for bindings in allBindings {
            bindings.writeParam(name: name, type: type, values: values)
        }
    }

    private static func makeFunction(device: MTLDevice, output: ShaderCompileOutput, file: ShaderFile) throws -> MTLFunction {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: output.msl, options: nil)
        } catch {
            throw ShaderCompileError(diagnostics: ShaderCompiler.parseDiagnostics(log: error.localizedDescription).map {
                $0.inFile(file)
            })
        }
        guard let function = library.makeFunction(name: output.reflection.entryPoint) else {
            throw ShaderCompileError(diagnostics: [
                ShaderDiagnostic(
                    line: nil,
                    message: "Missing entry point \(output.reflection.entryPoint) in compiled MSL",
                    file: file
                )
            ])
        }
        return function
    }

    private static func makePipeline(
        device: MTLDevice,
        descriptor: MTLRenderPipelineDescriptor,
        reflection: inout MTLAutoreleasedRenderPipelineReflection?
    ) throws -> MTLRenderPipelineState {
        do {
            return try device.makeRenderPipelineState(
                descriptor: descriptor,
                options: [.bindingInfo, .bufferTypeInfo],
                reflection: &reflection
            )
        } catch {
            throw ShaderCompileError(diagnostics: [
                ShaderDiagnostic(line: nil, message: error.localizedDescription)
            ])
        }
    }

    /// Straight (non-premultiplied) alpha, as fragment stages write it. The
    /// destination alpha accumulates coverage in every mode.
    private static func configureBlending(_ attachment: MTLRenderPipelineColorAttachmentDescriptor, blend: GeometryBlend) {
        switch blend {
        case .replace:
            attachment.isBlendingEnabled = false
        case .alpha:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
    }

    /// `Params` is one set of controls for the whole stage, so a member
    /// declared in several files must have the same type in each.
    private static func paramsConflicts(_ reflections: [(ShaderFile, ShaderReflection)]) -> [ShaderDiagnostic] {
        var seen: [String: (file: ShaderFile, type: String)] = [:]
        var conflicts: [ShaderDiagnostic] = []
        for (file, reflection) in reflections {
            for member in reflection.paramsBlock?.members ?? [] {
                let type = StageParameter.normalizeReflectionType(member.type)
                if let first = seen[member.name] {
                    if first.type != type {
                        conflicts.append(ShaderDiagnostic(
                            line: nil,
                            message: "Params member \(member.name) is \(type) here but \(first.type) in the \(first.file.title) tab; a name shared by several tabs must have one type",
                            file: file
                        ))
                    }
                } else {
                    seen[member.name] = (file, type)
                }
            }
        }
        return conflicts
    }
}
