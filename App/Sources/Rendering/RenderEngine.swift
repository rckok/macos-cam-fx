import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// GPU pipeline: imports captured frames, maintains the N-frame history as a
/// 3D texture, runs the effect chain, and produces output pixel buffers for
/// the virtual camera plus a texture for the preview.
final class RenderEngine {

    /// std140 layout of the CEContext uniform block declared in the prelude.
    private struct ContextUniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var timeDelta: Float
        var frameCount: Int32
        var headIndex: Int32
        var frameNumber: Int32
        var pad: Float = 0
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!
    let vertexFunction: MTLFunction
    private let blitPipeline: MTLRenderPipelineState
    private let flipHPipeline: MTLRenderPipelineState
    private let blitR8Pipeline: MTLRenderPipelineState
    private let flipHR8Pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private let visionProcessor: VisionProcessor
    private let handMaskRenderer: HandMaskRenderer
    /// 1x1 zero textures bound when a vision result is not available yet.
    private let fallbackMaskTexture: MTLTexture
    private let fallbackRGBATexture: MTLTexture

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "cameraEffects.render", qos: .userInteractive)

    // Protected by `lock`:
    private var effects: [RunningEffect] = []
    private var historyDepth: Int = 16
    private var flipHorizontal: Bool = true
    private var visionFeatures: VisionFeatures = []

    // Working resolution is always the virtual-camera size so the sink stream
    // receives buffers that match its declared format.
    private let outputWidth = VirtualCamera.width
    private let outputHeight = VirtualCamera.height

    // Only touched on the capture/render thread:
    private var historyTexture: MTLTexture?
    private var workingTexture: MTLTexture?
    private var personMatteTexture: MTLTexture?
    private var personMatteValid = false
    private var handMaskTexture: MTLTexture?
    private var pingPong: [MTLTexture] = []
    private var allocatedDepth = 0
    private var head = -1
    private var filledSlices = 0
    private var frameNumber: Int32 = 0
    private var startTime: CFTimeInterval?
    private var lastFrameTime: CFTimeInterval?
    private var outputPool: CVPixelBufferPool?

    /// Latest fully rendered output texture, for the preview view.
    private(set) var previewTexture: MTLTexture?

    /// Called on a Metal completion thread with each rendered output frame.
    var outputHandler: ((CVPixelBuffer, CMTime) -> Void)?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw NSError(domain: "CameraEffects", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
        }
        self.device = device
        self.commandQueue = queue

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        let library = try device.makeLibrary(source: BuiltinShaders.source, options: nil)
        guard let vertex = library.makeFunction(name: "ce_fullscreen_vertex"),
              let blitFragment = library.makeFunction(name: "ce_blit_fragment"),
              let flipFragment = library.makeFunction(name: "ce_blit_flip_h_fragment"),
              let handMaskFragment = library.makeFunction(name: "ce_hand_mask_fragment")
        else {
            throw NSError(domain: "CameraEffects", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing builtin shader functions"])
        }
        self.vertexFunction = vertex

        let makePipeline: (MTLFunction, MTLPixelFormat) throws -> MTLRenderPipelineState = { fragment, pixelFormat in
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.blitPipeline = try makePipeline(blitFragment, .bgra8Unorm)
        self.flipHPipeline = try makePipeline(flipFragment, .bgra8Unorm)
        self.blitR8Pipeline = try makePipeline(blitFragment, .r8Unorm)
        self.flipHR8Pipeline = try makePipeline(flipFragment, .r8Unorm)

        self.visionProcessor = VisionProcessor(device: device)
        self.handMaskRenderer = try HandMaskRenderer(
            device: device, vertexFunction: vertex, fragmentFunction: handMaskFragment
        )

        let makeFallback: (MTLPixelFormat, Int) throws -> MTLTexture = { pixelFormat, bytesPerPixel in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: 1, height: 1, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw NSError(domain: "CameraEffects", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create fallback texture"])
            }
            var zero = [UInt8](repeating: 0, count: bytesPerPixel)
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: bytesPerPixel)
            return texture
        }
        self.fallbackMaskTexture = try makeFallback(.r8Unorm, 1)
        self.fallbackRGBATexture = try makeFallback(.rgba8Unorm, 4)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw NSError(domain: "CameraEffects", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create sampler"])
        }
        self.sampler = sampler
    }

    // MARK: Configuration (called from the main thread)

    func setEffects(_ newEffects: [RunningEffect]) {
        // Vision algorithms only run while some enabled effect's compiled
        // shader actually uses their uniforms (per shader reflection).
        let features = newEffects.reduce(into: VisionFeatures()) { result, running in
            result.formUnion(VisionFeatures.required(by: running.compiled.reflection))
        }
        lock.lock()
        effects = newEffects
        visionFeatures = features
        lock.unlock()
        visionProcessor.setFeatures(features)
    }

    func setHistoryDepth(_ depth: Int) {
        lock.lock()
        historyDepth = max(1, min(depth, 120))
        lock.unlock()
    }

    func setFlipHorizontal(_ flip: Bool) {
        lock.lock()
        flipHorizontal = flip
        lock.unlock()
    }

    // MARK: Frame processing

    func process(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        renderQueue.async { [self] in
            processOnRenderQueue(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
    }

    private func processOnRenderQueue(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        lock.lock()
        let flip = flipHorizontal
        let activeVision = visionFeatures
        lock.unlock()

        // Vision-backed effects wait for the snapshot computed from this buffer
        // so mattes line up with the image. Intermediate camera frames replace
        // a single pending slot inside VisionProcessor (latest-wins).
        if !activeVision.isEmpty {
            visionProcessor.submit(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp,
                mirrored: flip
            ) { [weak self] buffer, time, mirrored, snapshot in
                self?.renderQueue.async {
                    self?.encodeFrame(
                        pixelBuffer: buffer,
                        timestamp: time,
                        mirrored: mirrored,
                        vision: snapshot
                    )
                }
            }
            return
        }

        encodeFrame(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            mirrored: flip,
            vision: VisionSnapshot()
        )
    }

    private func encodeFrame(
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        mirrored: Bool,
        vision: VisionSnapshot
    ) {
        lock.lock()
        let currentEffects = effects
        let depth = historyDepth
        let activeVision = visionFeatures
        lock.unlock()

        guard let frameTexture = makeTexture(from: pixelBuffer) else { return }

        ensureResources(depth: depth)
        guard let historyTexture, let workingTexture, let outputPool else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // 1. Scale (+ optional mirror) the capture frame into the fixed working
        //    resolution that matches the virtual camera.
        encodeBlit(
            commandBuffer: commandBuffer,
            pipeline: mirrored ? flipHPipeline : blitPipeline,
            source: frameTexture,
            destination: workingTexture
        )

        // 2. Append the processed frame to the history ring (slice `head`).
        head = (head + 1) % allocatedDepth
        filledSlices = min(filledSlices + 1, allocatedDepth)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: workingTexture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                to: historyTexture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: head)
            )
            blit.endEncoding()
        }

        // 3. Bind vision data computed from this same camera frame.
        if activeVision.contains(.personMatte), let matte = vision.personMatte, let personMatteTexture {
            // The matte is generated from the raw frame; blit it into vUV
            // orientation (stretch to output size, mirror when flipped).
            encodeBlit(
                commandBuffer: commandBuffer,
                pipeline: mirrored ? flipHR8Pipeline : blitR8Pipeline,
                source: matte,
                destination: personMatteTexture
            )
            personMatteValid = true
        }
        if activeVision.contains(.handMask), let handMaskTexture {
            handMaskRenderer.encode(
                commandBuffer: commandBuffer,
                target: handMaskTexture,
                hands: vision.hands,
                resolution: SIMD2<Float>(Float(outputWidth), Float(outputHeight))
            )
        }
        let faceSlots = VisionUniformPacking.packFace(rects: vision.faceRects)
        let handSlots = VisionUniformPacking.packHands(vision.hands)

        // 4. Timing / context uniforms.
        let now = CACurrentMediaTime()
        if startTime == nil { startTime = now }
        var context = ContextUniforms(
            resolution: SIMD2<Float>(Float(outputWidth), Float(outputHeight)),
            time: Float(now - (startTime ?? now)),
            timeDelta: Float(now - (lastFrameTime ?? now)),
            frameCount: Int32(allocatedDepth),
            headIndex: Int32(head),
            frameNumber: frameNumber
        )
        lastFrameTime = now
        frameNumber &+= 1

        // 5. Run the effect chain, ping-ponging between offscreen textures.
        var currentInput: MTLTexture = workingTexture
        var pingPongIndex = 0
        for running in currentEffects {
            running.textureAssets.advanceVideoFrames()

            let effect = running.compiled
            let target = pingPong[pingPongIndex]
            pingPongIndex = 1 - pingPongIndex

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setRenderPipelineState(effect.pipeline)

            for texture in effect.reflection.textures {
                let source: MTLTexture?
                switch texture.name {
                case "uPrev": source = currentInput
                case "uFrames": source = historyTexture
                case VisionUniforms.personMatteSampler:
                    source = (personMatteValid ? personMatteTexture : nil) ?? fallbackMaskTexture
                case VisionUniforms.faceMaskSampler:
                    source = vision.faceMask ?? fallbackRGBATexture
                case VisionUniforms.handMaskSampler:
                    source = (activeVision.contains(.handMask) ? handMaskTexture : nil) ?? fallbackMaskTexture
                default: source = running.textureAssets.texture(named: texture.name)
                }
                if let source, texture.mslTexture >= 0 {
                    encoder.setFragmentTexture(source, index: texture.mslTexture)
                }
                if texture.mslSampler >= 0 {
                    encoder.setFragmentSamplerState(sampler, index: texture.mslSampler)
                }
            }

            for block in effect.reflection.uniformBlocks where block.mslBuffer >= 0 {
                switch block.name {
                case "CEContext":
                    encoder.setFragmentBytes(&context, length: MemoryLayout<ContextUniforms>.stride, index: block.mslBuffer)
                case "Params":
                    if let paramsBuffer = effect.paramsBuffer {
                        encoder.setFragmentBuffer(paramsBuffer, offset: 0, index: block.mslBuffer)
                    }
                case VisionUniforms.faceBlock:
                    faceSlots.withUnsafeBytes { bytes in
                        encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: block.mslBuffer)
                    }
                case VisionUniforms.handsBlock:
                    handSlots.withUnsafeBytes { bytes in
                        encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: block.mslBuffer)
                    }
                default:
                    break
                }
            }

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            currentInput = target
        }

        // 6. Copy the final image into a fresh IOSurface-backed pixel buffer
        //    for the virtual camera sink (always VirtualCamera dimensions).
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, outputPool, nil, &outputBuffer)
        if let outputBuffer, let outputTexture = makeTexture(from: outputBuffer) {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: currentInput, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                    to: outputTexture, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.outputHandler?(outputBuffer, timestamp)
            }
        }

        previewTexture = currentInput
        commandBuffer.commit()
    }

    /// Draws `texture` into a drawable's render pass (used by the preview view).
    func encodePreviewBlit(texture: MTLTexture, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(blitPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: Private helpers

    private func encodeBlit(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        source: MTLTexture,
        destination: MTLTexture
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func ensureResources(depth: Int) {
        guard depth != allocatedDepth || historyTexture == nil || workingTexture == nil || pingPong.count != 2 || outputPool == nil else {
            return
        }

        allocatedDepth = depth
        head = -1
        filledSlices = 0

        let historyDescriptor = MTLTextureDescriptor()
        historyDescriptor.textureType = .type3D
        historyDescriptor.pixelFormat = .bgra8Unorm
        historyDescriptor.width = outputWidth
        historyDescriptor.height = outputHeight
        historyDescriptor.depth = depth
        historyDescriptor.usage = [.shaderRead]
        historyDescriptor.storageMode = .private
        historyTexture = device.makeTexture(descriptor: historyDescriptor)

        let workingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false
        )
        workingDescriptor.usage = [.renderTarget, .shaderRead]
        workingDescriptor.storageMode = .private
        workingTexture = device.makeTexture(descriptor: workingDescriptor)

        if personMatteTexture == nil || handMaskTexture == nil {
            let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: outputWidth, height: outputHeight, mipmapped: false
            )
            maskDescriptor.usage = [.renderTarget, .shaderRead]
            maskDescriptor.storageMode = .private
            personMatteTexture = device.makeTexture(descriptor: maskDescriptor)
            personMatteValid = false
            handMaskTexture = device.makeTexture(descriptor: maskDescriptor)
        }

        let pingPongDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false
        )
        pingPongDescriptor.usage = [.renderTarget, .shaderRead]
        pingPongDescriptor.storageMode = .private
        pingPong = [
            device.makeTexture(descriptor: pingPongDescriptor)!,
            device.makeTexture(descriptor: pingPongDescriptor)!,
        ]

        let poolAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &pool)
        outputPool = pool
    }
}
