import Foundation
import Metal

/// A user effect compiled into a Metal pipeline, plus the reflected resource
/// bindings and a CPU-side parameter buffer laid out to match std140.
final class CompiledEffect {
    let pipeline: MTLRenderPipelineState
    let reflection: ShaderReflection
    /// Warnings from GLSL compile that did not fail the build.
    let warnings: [ShaderDiagnostic]
    /// Buffer backing the user's `Params` block; nil when the shader has none.
    let paramsBuffer: MTLBuffer?
    /// Metal constant-buffer lengths keyed by MSL buffer index. SPIR-V
    /// `get_declared_struct_size` omits trailing 16-byte padding that the
    /// Metal compiler adds, which otherwise fails validation (e.g. 88 vs 96).
    private let constantBufferLengths: [Int: Int]

    init(device: MTLDevice, vertexFunction: MTLFunction, output: ShaderCompileOutput) throws {
        self.reflection = output.reflection
        self.warnings = output.diagnostics

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: output.msl, options: nil)
        } catch {
            throw ShaderCompileError(diagnostics: ShaderCompiler.parseDiagnostics(log: error.localizedDescription))
        }
        guard let fragmentFunction = library.makeFunction(name: output.reflection.entryPoint) else {
            throw ShaderCompileError(diagnostics: [
                ShaderDiagnostic(line: nil, message: "Missing entry point \(output.reflection.entryPoint) in compiled MSL")
            ])
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        var pipelineReflection: MTLAutoreleasedRenderPipelineReflection?
        self.pipeline = try device.makeRenderPipelineState(
            descriptor: descriptor,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &pipelineReflection
        )
        let metalLengths = Self.constantBufferLengths(from: pipelineReflection)
        self.constantBufferLengths = metalLengths

        if let block = output.reflection.paramsBlock, block.mslBuffer >= 0, block.size > 0 {
            let length = Self.constantBufferLength(spirvSize: block.size, metalSize: metalLengths[block.mslBuffer])
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

    private static func constantBufferLengths(from reflection: MTLRenderPipelineReflection?) -> [Int: Int] {
        var lengths: [Int: Int] = [:]
        for binding in reflection?.fragmentBindings ?? [] {
            guard let buffer = binding as? MTLBufferBinding, buffer.bufferDataSize > 0 else { continue }
            lengths[buffer.index] = buffer.bufferDataSize
        }
        return lengths
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
