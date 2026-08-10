import Foundation
import Metal

/// A user effect compiled into a Metal pipeline, plus the reflected resource
/// bindings and a CPU-side parameter buffer laid out to match std140.
final class CompiledEffect {
    let pipeline: MTLRenderPipelineState
    let reflection: ShaderReflection
    /// Buffer backing the user's `Params` block; nil when the shader has none.
    let paramsBuffer: MTLBuffer?

    init(device: MTLDevice, vertexFunction: MTLFunction, output: ShaderCompileOutput) throws {
        self.reflection = output.reflection

        let library = try device.makeLibrary(source: output.msl, options: nil)
        guard let fragmentFunction = library.makeFunction(name: output.reflection.entryPoint) else {
            throw ShaderCompileError(diagnostics: [
                ShaderDiagnostic(line: nil, message: "Missing entry point \(output.reflection.entryPoint) in compiled MSL")
            ])
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        if let block = output.reflection.paramsBlock, block.mslBuffer >= 0, block.size > 0 {
            self.paramsBuffer = device.makeBuffer(length: block.size, options: .storageModeShared)
        } else {
            self.paramsBuffer = nil
        }
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
        case "uint", "bool":
            base.storeBytes(of: UInt32(values.first ?? 0), as: UInt32.self)
        default:
            break
        }
    }
}
