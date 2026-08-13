import Foundation
import Metal
import simd

/// Renders an approximate hand silhouette into an r8 target from the detected
/// skeleton. The palm is a rounded rectangle (wrist bar, sides, inset knuckle
/// line) rather than spokes converging on the wrist; fingers and thumb are
/// separate tapered bones. Capsule radii scale with palm length so the mask
/// tracks hands at any distance.
final class HandMaskRenderer {

    static let maxCapsules = 64

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
        var radii: [SIMD2<Float>] = []
        for hand in hands.prefix(VisionUniforms.maxHands) {
            appendCapsules(for: hand, resolution: resolution, segments: &segments, radii: &radii)
        }

        var slots = [SIMD4<Float>](repeating: .zero, count: 1 + 2 * Self.maxCapsules)
        let count = min(segments.count, Self.maxCapsules)
        slots[0] = SIMD4<Float>(resolution.x, resolution.y, Float(count), 0)
        for index in 0..<count {
            slots[1 + index] = segments[index]
            slots[1 + Self.maxCapsules + index] = SIMD4<Float>(radii[index].x, radii[index].y, 0, 0)
        }
        return slots
    }

    private func appendCapsules(
        for hand: VisionHand,
        resolution: SIMD2<Float>,
        segments: inout [SIMD4<Float>],
        radii: inout [SIMD2<Float>]
    ) {
        let minimumConfidence: Float = 0.3

        func pixel(_ jointIndex: Int) -> SIMD2<Float>? {
            guard jointIndex < hand.joints.count else { return nil }
            let joint = hand.joints[jointIndex]
            guard joint.z >= minimumConfidence else { return nil }
            return SIMD2<Float>(joint.x, joint.y) * resolution
        }

        func addSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, from startRadius: Float, to endRadius: Float? = nil) {
            segments.append(SIMD4<Float>(a.x, a.y, b.x, b.y))
            let end = endRadius ?? startRadius
            radii.append(SIMD2<Float>(startRadius, end))
        }

        // Palm length (wrist → middle knuckle) is a stable size estimate;
        // spread fingertips are not.
        guard let wrist = pixel(0), let middleMCP = pixel(9) else { return }
        let palmVec = middleMCP - wrist
        let scale = max(simd_length(palmVec), 1)
        let palmDir = palmVec / scale
        // Wrist is narrower than the knuckles (~1/2 of palm length). Align the
        // crease perpendicular to the palm axis so spread fingers cannot
        // inflate the heel of the hand.
        let wristWidth = 0.52 * scale
        var wristAxis = SIMD2<Float>(-palmDir.y, palmDir.x)
        let indexMCP = pixel(5)
        let ringMCP = pixel(13)
        let littleMCP = pixel(17)
        if let indexMCP, let littleMCP, simd_dot(wristAxis, littleMCP - indexMCP) < 0 {
            wristAxis = -wristAxis
        }
        let radialWrist = wrist - wristAxis * (wristWidth * 0.5)
        let ulnarWrist = wrist + wristAxis * (wristWidth * 0.5)

        let knuckleRadius = 0.12 * scale
        let webbingInset = 1.15 * knuckleRadius

        func insetTowardWrist(_ point: SIMD2<Float>) -> SIMD2<Float> {
            point - palmDir * webbingInset
        }

        let distalHalf = wristAxis * (0.68 * scale * 0.5)
        let radialKnuckle = indexMCP ?? (middleMCP - distalHalf)
        let ulnarKnuckle = littleMCP ?? (middleMCP + distalHalf)
        let radialInset = insetTowardWrist(radialKnuckle)
        let middleInset = insetTowardWrist(middleMCP)
        let ulnarInset = insetTowardWrist(ulnarKnuckle)

        func mix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
            a + (b - a) * t
        }

        // Overlapping ribs fill the palm trapezoid; outline-only capsules
        // left a hole in the center.
        let ribCount = 5
        let distalWidth = max(simd_length(ulnarInset - radialInset), 1)
        let startRadius = 0.68 * wristWidth / Float(ribCount - 1)
        let endRadius = 0.68 * distalWidth / Float(ribCount - 1)
        addSegment(radialWrist, ulnarWrist, from: 0.10 * scale)
        for rib in 0..<ribCount {
            let t = Float(rib) / Float(ribCount - 1)
            addSegment(
                mix(radialWrist, ulnarWrist, t),
                mix(radialInset, ulnarInset, t),
                from: startRadius,
                to: endRadius
            )
        }
        addSegment(radialInset, middleInset, from: knuckleRadius)
        if let ringMCP {
            let ringInset = insetTowardWrist(ringMCP)
            addSegment(middleInset, ringInset, from: knuckleRadius)
            addSegment(ringInset, ulnarInset, from: knuckleRadius)
        } else {
            addSegment(middleInset, ulnarInset, from: knuckleRadius)
        }

        // Fingers start at the MCP — never at the wrist.
        let fingerChains: [(joints: [Int], width: Float)] = [
            ([5, 6, 7, 8], 1.00),
            ([9, 10, 11, 12], 1.04),
            ([13, 14, 15, 16], 0.98),
            ([17, 18, 19, 20], 0.88),
        ]
        let proximalRadius = 0.155 * scale
        let medialRadius = 0.132 * scale
        let distalRadius = 0.112 * scale
        for (joints, width) in fingerChains {
            let startRadii = [proximalRadius, medialRadius, distalRadius].map { $0 * width }
            let endRadii = [medialRadius, distalRadius, distalRadius * 0.92].map { $0 * width }
            for segment in 0..<(joints.count - 1) {
                guard let a = pixel(joints[segment]), let b = pixel(joints[segment + 1]) else { continue }
                addSegment(a, b, from: startRadii[segment], to: endRadii[segment])
            }
        }

        // Thenar mass on the radial palm, then the two thumb phalanges.
        // Connecting the thumb to the wrist as a finger spoke is what produced
        // the long, thin thumb.
        let thumbCMC = pixel(1)
        let thumbMP = pixel(2)
        // Root the thenar on the radial palm, inset from the wrist corner so
        // it does not flare the heel of the hand.
        let thenarRoot = mix(radialWrist, ulnarWrist, 0.18) + palmDir * (0.10 * scale)
        if let thumbMP {
            addSegment(thenarRoot, thumbMP, from: 0.16 * scale, to: 0.14 * scale)
            if let thumbCMC {
                addSegment(thumbCMC, thumbMP, from: 0.15 * scale, to: 0.14 * scale)
                addSegment(thenarRoot, thumbCMC, from: 0.14 * scale)
            }
            if let thumbIP = pixel(3) {
                addSegment(thumbMP, thumbIP, from: 0.155 * scale, to: 0.135 * scale)
                if let thumbTip = pixel(4) {
                    addSegment(thumbIP, thumbTip, from: 0.135 * scale, to: 0.115 * scale)
                }
            }
        }
    }
}
