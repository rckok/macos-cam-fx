import Foundation
import Metal

/// Names and limits of the vision-data uniforms injected by the shader prelude.
enum VisionUniforms {
    static let personMatteSampler = "uPersonMatte"
    static let faceMaskSampler = "uFaceMask"
    static let handMaskSampler = "uHandMask"
    static let faceBlock = "CEFace"
    static let facePointsBlock = "CEFacePoints"
    static let handsBlock = "CEHands"

    static let maxFaces = 4
    static let maxHands = 2
    static let handJointCount = 21
}

/// The set of vision algorithms an effect chain requires. Derived from shader
/// reflection so detectors only run while some enabled effect uses their output.
struct VisionFeatures: OptionSet, Hashable {
    let rawValue: Int

    /// Person segmentation producing the `uPersonMatte` luma matte.
    static let personMatte = VisionFeatures(rawValue: 1 << 0)
    /// Face rectangle detection filling the `CEFace` block.
    static let faceRects = VisionFeatures(rawValue: 1 << 1)
    /// Face landmark detection rasterized into `uFaceMask` (implies face rects).
    static let faceMask = VisionFeatures(rawValue: 1 << 2)
    /// Hand pose detection filling the `CEHands` block.
    static let handPose = VisionFeatures(rawValue: 1 << 3)
    /// Approximate hand silhouette rendered into `uHandMask` (implies hand pose).
    static let handMask = VisionFeatures(rawValue: 1 << 4)
    /// Eye and mouth centers from face landmarks, filling the `CEFacePoints`
    /// block (implies face rects).
    static let facePoints = VisionFeatures(rawValue: 1 << 5)

    var needsFaceDetection: Bool { !isDisjoint(with: [.faceRects, .faceMask, .facePoints]) }
    /// Landmarks are strictly more expensive than rectangles, so they are only
    /// requested for the features that actually read them.
    var needsFaceLandmarks: Bool { !isDisjoint(with: [.faceMask, .facePoints]) }
    var needsHandDetection: Bool { !isDisjoint(with: [.handPose, .handMask]) }

    /// Features used by one compiled shader. A prelude uniform that the user
    /// source never references is dead-code-eliminated by the transpiler and
    /// reported with a negative Metal resource index, so it does not count.
    static func required(by reflection: ShaderReflection) -> VisionFeatures {
        var features: VisionFeatures = []
        for texture in reflection.textures where texture.mslTexture >= 0 {
            switch texture.name {
            case VisionUniforms.personMatteSampler: features.insert(.personMatte)
            case VisionUniforms.faceMaskSampler: features.insert(.faceMask)
            case VisionUniforms.handMaskSampler: features.insert(.handMask)
            default: break
            }
        }
        for block in reflection.uniformBlocks where block.mslBuffer >= 0 {
            switch block.name {
            case VisionUniforms.faceBlock: features.insert(.faceRects)
            case VisionUniforms.facePointsBlock: features.insert(.facePoints)
            case VisionUniforms.handsBlock: features.insert(.handPose)
            default: break
            }
        }
        return features
    }
}

/// One detected hand in vUV space (top-left origin, mirroring applied).
struct VisionHand {
    /// -1 = left, +1 = right, 0 = unknown.
    var chirality: Float
    var confidence: Float
    /// Exactly `VisionUniforms.handJointCount` entries in prelude joint order:
    /// xy = vUV position, z = joint confidence, w unused.
    var joints: [SIMD4<Float>]
}

/// Landmark-derived centers of one detected face, in vUV space. Each entry is
/// xy = center, z = 1 when the region was located (0 otherwise), w = half the
/// region's width, normalized to the frame width like `faceRects`' size.
struct VisionFacePoints {
    var leftEye: SIMD4<Float> = .zero
    var rightEye: SIMD4<Float> = .zero
    var mouth: SIMD4<Float> = .zero
}

/// Vision results for one camera frame, produced by `VisionProcessor` and
/// consumed by the render thread together with that same frame. All coordinates
/// and mask textures are in vUV space, except `personMatte`, which is
/// unmirrored (the engine blits it into orientation).
struct VisionSnapshot {
    /// xy = top-left origin, zw = size, in vUV space. At most `maxFaces`.
    var faceRects: [SIMD4<Float>] = []
    /// Parallel to `faceRects` when face landmarks were requested, else empty.
    var facePoints: [VisionFacePoints] = []
    /// At most `maxHands`.
    var hands: [VisionHand] = []
    /// r8Unorm person matte imported from Vision; 1 = person. Not mirrored.
    var personMatte: MTLTexture?
    /// rgba8Unorm eye/mouth mask, already in vUV space.
    var faceMask: MTLTexture?
}

/// std140 packing of the `CEFace`, `CEFacePoints`, and `CEHands` prelude blocks
/// as vec4 slots.
/// Block-level ints are stored via bit pattern in the first slot's x lane.
enum VisionUniformPacking {

    /// CEFace: int uFaceCount (offset 0), vec4 uFaceRects[4] (offset 16). 80 bytes.
    static func packFace(rects: [SIMD4<Float>]) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: .zero, count: 1 + VisionUniforms.maxFaces)
        let count = min(rects.count, VisionUniforms.maxFaces)
        slots[0].x = Float(bitPattern: UInt32(bitPattern: Int32(count)))
        for index in 0..<count {
            slots[1 + index] = rects[index]
        }
        return slots
    }

    /// CEFacePoints: vec4 uFaceLeftEye[4] (offset 0), vec4 uFaceRightEye[4]
    /// (offset 64), vec4 uFaceMouth[4] (offset 128). 192 bytes.
    static func packFacePoints(_ points: [VisionFacePoints]) -> [SIMD4<Float>] {
        let maxFaces = VisionUniforms.maxFaces
        var slots = [SIMD4<Float>](repeating: .zero, count: 3 * maxFaces)
        for index in 0..<min(points.count, maxFaces) {
            slots[index] = points[index].leftEye
            slots[maxFaces + index] = points[index].rightEye
            slots[2 * maxFaces + index] = points[index].mouth
        }
        return slots
    }

    /// CEHands: int uHandCount (offset 0), vec4 uHandInfo[2] (offset 16),
    /// vec4 uHandJoints[42] (offset 48). 720 bytes.
    static func packHands(_ hands: [VisionHand]) -> [SIMD4<Float>] {
        let jointCount = VisionUniforms.handJointCount
        var slots = [SIMD4<Float>](
            repeating: .zero,
            count: 1 + VisionUniforms.maxHands + VisionUniforms.maxHands * jointCount
        )
        let count = min(hands.count, VisionUniforms.maxHands)
        slots[0].x = Float(bitPattern: UInt32(bitPattern: Int32(count)))
        for handIndex in 0..<count {
            let hand = hands[handIndex]
            slots[1 + handIndex] = SIMD4<Float>(hand.chirality, hand.confidence, 0, 0)
            let base = 1 + VisionUniforms.maxHands + handIndex * jointCount
            for jointIndex in 0..<min(jointCount, hand.joints.count) {
                slots[base + jointIndex] = hand.joints[jointIndex]
            }
        }
        return slots
    }
}
