import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision

/// Runs the Vision requests implied by the active feature set on a background
/// queue, converts results into vUV space, and publishes snapshots for the
/// render thread.
///
/// - Only the requests required by the current feature set are created; with
///   an empty set the processor is fully idle.
/// - Frames are dropped while a previous frame is still being analyzed
///   (latest-wins), so the render loop never blocks on Vision.
final class VisionProcessor {

    private let device: MTLDevice
    private let queue = DispatchQueue(label: "cameraEffects.vision", qos: .userInitiated)
    private let lock = NSLock()

    // Protected by `lock`:
    private var features: VisionFeatures = []
    private var latest = VisionSnapshot()
    private var busy = false

    // Only touched on `queue`:
    private var requestFeatures: VisionFeatures = []
    private var faceRequest: VNImageBasedRequest?
    private var handRequest: VNDetectHumanHandPoseRequest?
    private var matteRequest: VNGeneratePersonSegmentationRequest?
    private let faceMaskRasterizer = FaceMaskRasterizer()
    private var matteTextures: [MTLTexture] = []
    private var matteTextureIndex = 0

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: Render-thread interface

    /// Reconfigures which algorithms run. Called whenever the effect chain
    /// changes; results of features no longer needed are dropped immediately.
    func setFeatures(_ newFeatures: VisionFeatures) {
        lock.lock()
        defer { lock.unlock() }
        guard newFeatures != features else { return }
        features = newFeatures
        if !newFeatures.contains(.personMatte) { latest.personMatte = nil }
        if !newFeatures.contains(.faceMask) { latest.faceMask = nil }
        if !newFeatures.needsFaceDetection { latest.faceRects = [] }
        if !newFeatures.needsHandDetection { latest.hands = [] }
    }

    /// Latest published results (≤ one camera frame behind).
    func snapshot() -> VisionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Queues a frame for analysis unless one is already in flight.
    /// `mirrored` mirrors observation coordinates to match the flipped
    /// working texture the effects sample.
    func submit(pixelBuffer: CVPixelBuffer, mirrored: Bool) {
        lock.lock()
        let activeFeatures = features
        guard !activeFeatures.isEmpty, !busy else {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()

        queue.async { [weak self] in
            self?.analyze(pixelBuffer: pixelBuffer, mirrored: mirrored, features: activeFeatures)
        }
    }

    // MARK: Analysis (vision queue)

    private func analyze(pixelBuffer: CVPixelBuffer, mirrored: Bool, features: VisionFeatures) {
        updateRequests(for: features)
        let requests: [VNRequest] = [faceRequest, handRequest, matteRequest].compactMap { $0 }

        var snapshot: VisionSnapshot?
        if !requests.isEmpty {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform(requests)
                snapshot = buildSnapshot(pixelBuffer: pixelBuffer, mirrored: mirrored, features: features)
            } catch {
                NSLog("Vision analysis failed: \(error)")
            }
        }

        lock.lock()
        if let snapshot, self.features == features {
            latest = snapshot
        }
        busy = false
        lock.unlock()
    }

    /// Requests are cached and reused across frames (person segmentation is
    /// stateful and benefits from temporal consistency); they are rebuilt only
    /// when the feature set changes.
    private func updateRequests(for features: VisionFeatures) {
        guard features != requestFeatures else { return }
        requestFeatures = features

        if features.contains(.faceMask) {
            faceRequest = VNDetectFaceLandmarksRequest()
        } else if features.contains(.faceRects) {
            faceRequest = VNDetectFaceRectanglesRequest()
        } else {
            faceRequest = nil
        }

        if features.needsHandDetection {
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = VisionUniforms.maxHands
            handRequest = request
        } else {
            handRequest = nil
        }

        if features.contains(.personMatte) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            matteRequest = request
        } else {
            matteRequest = nil
        }
    }

    private func buildSnapshot(pixelBuffer: CVPixelBuffer, mirrored: Bool, features: VisionFeatures) -> VisionSnapshot {
        var snapshot = VisionSnapshot()

        let faceObservations = (faceRequest?.results as? [VNFaceObservation]) ?? []
        snapshot.faceRects = faceObservations
            .prefix(VisionUniforms.maxFaces)
            .map { convert(rect: $0.boundingBox, mirrored: mirrored) }

        if features.contains(.faceMask) {
            let imageSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let regions = faceObservations.map { face in
                faceRegions(for: face, imageSize: imageSize, mirrored: mirrored)
            }
            snapshot.faceMask = faceMaskRasterizer.rasterize(faces: regions, device: device)
        }

        if let handRequest {
            snapshot.hands = (handRequest.results ?? [])
                .prefix(VisionUniforms.maxHands)
                .map { convert(hand: $0, mirrored: mirrored) }
        }

        if let matteBuffer = matteRequest?.results?.first?.pixelBuffer {
            snapshot.personMatte = importMatte(matteBuffer)
        }

        return snapshot
    }

    // MARK: Coordinate conversion (Vision lower-left origin -> vUV top-left origin)

    private func convert(rect: CGRect, mirrored: Bool) -> SIMD4<Float> {
        let x = mirrored ? 1 - rect.maxX : rect.minX
        let y = 1 - rect.maxY
        return SIMD4<Float>(Float(x), Float(y), Float(rect.width), Float(rect.height))
    }

    private func convert(point: CGPoint, mirrored: Bool) -> SIMD2<Float> {
        SIMD2<Float>(Float(mirrored ? 1 - point.x : point.x), Float(1 - point.y))
    }

    /// Canonical joint order matching the CE_* indices in the shader prelude.
    private static let handJointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    private func convert(hand observation: VNHumanHandPoseObservation, mirrored: Bool) -> VisionHand {
        let points = (try? observation.recognizedPoints(.all)) ?? [:]
        let joints = Self.handJointOrder.map { name -> SIMD4<Float> in
            guard let point = points[name] else { return .zero }
            let uv = convert(point: point.location, mirrored: mirrored)
            return SIMD4<Float>(uv.x, uv.y, Float(point.confidence), 0)
        }
        let chirality: Float
        switch observation.chirality {
        case .left: chirality = -1
        case .right: chirality = 1
        default: chirality = 0
        }
        return VisionHand(chirality: chirality, confidence: Float(observation.confidence), joints: joints)
    }

    private func faceRegions(
        for face: VNFaceObservation,
        imageSize: CGSize,
        mirrored: Bool
    ) -> FaceMaskRasterizer.FaceRegions {
        func polygon(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: imageSize).map { point in
                let normalized = CGPoint(x: point.x / imageSize.width, y: point.y / imageSize.height)
                let uv = convert(point: normalized, mirrored: mirrored)
                return CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y))
            }
        }
        return FaceMaskRasterizer.FaceRegions(
            leftEye: polygon(face.landmarks?.leftEye),
            rightEye: polygon(face.landmarks?.rightEye),
            mouth: polygon(face.landmarks?.outerLips)
        )
    }

    // MARK: Person matte import

    /// Uploads the matte into a small ring of owned r8 textures. Vision mattes
    /// are model-resolution (much smaller than the output), so a CPU upload is
    /// cheap and avoids CVMetalTexture lifetime management.
    private func importMatte(_ buffer: CVPixelBuffer) -> MTLTexture? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        if matteTextures.first?.width != width || matteTextures.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            matteTextures = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            matteTextureIndex = 0
            guard matteTextures.count == 3 else {
                matteTextures = []
                return nil
            }
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let texture = matteTextures[matteTextureIndex]
        matteTextureIndex = (matteTextureIndex + 1) % matteTextures.count
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: base,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
        )
        return texture
    }
}
