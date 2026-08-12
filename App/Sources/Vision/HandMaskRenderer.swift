import Foundation
import Metal
import simd

/// Renders an approximate hand silhouette into an r8 target by drawing SDF
/// capsules along the detected skeleton: finger bones, wrist-to-knuckle
/// spokes, the knuckle line, and a fat palm capsule. Capsule radii scale with
/// the detected hand size, so the mask tracks hands at any distance.
final class HandMaskRenderer {

    static let maxCapsules = 48

    private let pipeline: MTLRenderPipelineState

    init(device: MTLDevice, vertexFunction: MTLFunction, fragmentFunction: MTLFunction) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .r8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Encodes the mask pass. With no hands the target is cleared to zero.
    func encode(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        hands: [VisionHand],
        resolution: SIMD2<Float>
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        var slots = uniformSlots(hands: hands, resolution: resolution)
        slots.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Packs CEHandMaskUniforms (see BuiltinShaders): header slot, then
    /// `maxCapsules` segment slots, then `maxCapsules` radius slots.
    private func uniformSlots(hands: [VisionHand], resolution: SIMD2<Float>) -> [SIMD4<Float>] {
        var segments: [SIMD4<Float>] = []
        var radii: [Float] = []
        for hand in hands.prefix(VisionUniforms.maxHands) {
            appendCapsules(for: hand, resolution: resolution, segments: &segments, radii: &radii)
        }

        var slots = [SIMD4<Float>](repeating: .zero, count: 1 + 2 * Self.maxCapsules)
        let count = min(segments.count, Self.maxCapsules)
        slots[0] = SIMD4<Float>(resolution.x, resolution.y, Float(count), 0)
        for index in 0..<count {
            slots[1 + index] = segments[index]
            slots[1 + Self.maxCapsules + index] = SIMD4<Float>(radii[index], 0, 0, 0)
        }
        return slots
    }

    private func appendCapsules(
        for hand: VisionHand,
        resolution: SIMD2<Float>,
        segments: inout [SIMD4<Float>],
        radii: inout [Float]
    ) {
        let minimumConfidence: Float = 0.3

        func pixel(_ jointIndex: Int) -> SIMD2<Float>? {
            guard jointIndex < hand.joints.count else { return nil }
            let joint = hand.joints[jointIndex]
            guard joint.z >= minimumConfidence else { return nil }
            return SIMD2<Float>(joint.x, joint.y) * resolution
        }

        func addSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, radius: Float) {
            segments.append(SIMD4<Float>(a.x, a.y, b.x, b.y))
            radii.append(radius)
        }

        // The hand scale anchors all radii; without wrist + middle knuckle
        // there is no reliable size estimate, so skip the hand.
        guard let wrist = pixel(0), let middleMCP = pixel(9) else { return }
        let scale = max(simd_distance(wrist, middleMCP), 1)
        let fingerRadius = 0.09 * scale
        let spokeRadius = 0.14 * scale
        let knuckleRadius = 0.12 * scale
        let palmRadius = 0.30 * scale

        // Wrist -> knuckle -> ... -> fingertip, one chain per digit
        // (joint indices follow the CE_* order in the shader prelude).
        let chains: [[Int]] = [
            [0, 1, 2, 3, 4],
            [0, 5, 6, 7, 8],
            [0, 9, 10, 11, 12],
            [0, 13, 14, 15, 16],
            [0, 17, 18, 19, 20],
        ]
        for chain in chains {
            for segment in 0..<(chain.count - 1) {
                guard let a = pixel(chain[segment]), let b = pixel(chain[segment + 1]) else { continue }
                addSegment(a, b, radius: segment == 0 ? spokeRadius : fingerRadius)
            }
        }

        for (from, to) in [(5, 9), (9, 13), (13, 17)] {
            guard let a = pixel(from), let b = pixel(to) else { continue }
            addSegment(a, b, radius: knuckleRadius)
        }

        addSegment(wrist, middleMCP, radius: palmRadius)
    }
}
