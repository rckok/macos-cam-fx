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
    private let sampler: MTLSamplerState

    private let lock = NSLock()

    // Protected by `lock`:
    private var effects: [RunningEffect] = []
    private var historyDepth: Int = 16
    private var flipHorizontal: Bool = true

    // Working resolution is always the virtual-camera size so the sink stream
    // receives buffers that match its declared format.
    private let outputWidth = VirtualCamera.width
    private let outputHeight = VirtualCamera.height

    // Only touched on the capture/render thread:
    private var historyTexture: MTLTexture?
    private var workingTexture: MTLTexture?
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
              let flipFragment = library.makeFunction(name: "ce_blit_flip_h_fragment")
        else {
            throw NSError(domain: "CameraEffects", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing builtin shader functions"])
        }
        self.vertexFunction = vertex

        let makePipeline: (MTLFunction) throws -> MTLRenderPipelineState = { fragment in
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.blitPipeline = try makePipeline(blitFragment)
        self.flipHPipeline = try makePipeline(flipFragment)

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
        lock.lock()
        effects = newEffects
        lock.unlock()
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

    // MARK: Frame processing (called on the capture queue)

    func process(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        lock.lock()
        let currentEffects = effects
        let depth = historyDepth
        let flip = flipHorizontal
        lock.unlock()

        guard let frameTexture = makeTexture(from: pixelBuffer) else { return }

        ensureResources(depth: depth)
        guard let historyTexture, let workingTexture, let outputPool else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // 1. Scale (+ optional mirror) the capture frame into the fixed working
        //    resolution that matches the virtual camera.
        encodeBlit(
            commandBuffer: commandBuffer,
            pipeline: flip ? flipHPipeline : blitPipeline,
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

        // 3. Timing / context uniforms.
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

        // 4. Run the effect chain, ping-ponging between offscreen textures.
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
                default:
                    break
                }
            }

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            currentInput = target
        }

        // 5. Copy the final image into a fresh IOSurface-backed pixel buffer
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
