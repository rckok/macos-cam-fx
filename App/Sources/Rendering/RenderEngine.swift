import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// GPU pipeline: imports captured frames, maintains the N-frame history as a
/// 3D texture, runs the active effect's stages, and produces output pixel
/// buffers for the virtual camera plus a texture for the preview.
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
    private var stages: [RunningStage] = []
    /// Stages in the active effect, rendered or not; sizes `uStageTextures`.
    private var stageCount: Int = 0
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
    /// Every stage renders here, then the result is copied into its slice of
    /// `stageTextures`, so no pass ever reads the texture it writes.
    private var scratchTexture: MTLTexture?
    /// `uStageTextures`: one slice per stage of the active effect. Sized to
    /// that effect alone and released when it has no stages, so GPU memory
    /// never accumulates for inactive effects.
    private var stageTextures: MTLTexture?
    /// 2D views of each slice, for `uPrev`, the output copy and the preview.
    private var stageSliceViews: [MTLTexture] = []
    private var allocatedStageCount = 0
    private var stageTexturesNeedClear = false
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

    /// `stageCount` is the number of stages in the active effect, including
    /// ones that are skipped; it fixes the slice numbering of `uStageTextures`.
    func setStages(_ newStages: [RunningStage], stageCount newStageCount: Int) {
        // Vision algorithms only run while a stage of the active effect
        // actually uses their uniforms (per shader reflection).
        let features = newStages.reduce(into: VisionFeatures()) { result, running in
            result.formUnion(VisionFeatures.required(by: running.compiled.reflection))
        }
        lock.lock()
        stages = newStages
        stageCount = max(newStageCount, newStages.map { $0.index + 1 }.max() ?? 0)
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

        // Vision-backed stages wait for the snapshot computed from this buffer
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
        let currentStages = stages
        let currentStageCount = stageCount
        let depth = historyDepth
        let activeVision = visionFeatures
        lock.unlock()

        guard let frameTexture = makeTexture(from: pixelBuffer) else { return }

        ensureResources(depth: depth)
        ensureStageTextures(count: currentStageCount)
        guard let historyTexture, let workingTexture, let outputPool else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Freshly allocated stage slices read as transparent black until their
        // stage has run once, so feedback and forward references are defined.
        if stageTexturesNeedClear, let stageTextures {
            for slice in 0..<stageTextures.arrayLength {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = stageTextures
                pass.colorAttachments[0].slice = slice
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .store
                commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            stageTexturesNeedClear = false
        }

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
        let facePointSlots = VisionUniformPacking.packFacePoints(vision.facePoints)
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

        // 5. Run the active effect's stages. Each renders into the scratch
        //    texture and is then copied into its slice of `uStageTextures`, so
        //    a stage reading its own slice sees its previous frame (feedback)
        //    and later stages see this frame's result. The first rendered stage
        //    samples the camera frame through `uPrev`, so nothing carries over
        //    from whichever effect ran before.
        var currentInput: MTLTexture = workingTexture
        for running in currentStages {
            guard let scratchTexture, let stageTextures,
                  stageSliceViews.indices.contains(running.index)
            else { continue }
            running.textureAssets.advanceVideoFrames()

            let stage = running.compiled
            let stagesUniforms = Self.stagesUniformBytes(
                index: running.index, count: currentStageCount, refs: running.stageRefs
            )

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = scratchTexture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setRenderPipelineState(stage.pipeline)

            for texture in stage.reflection.textures {
                let source: MTLTexture?
                switch texture.name {
                case ShaderReflection.previousOutputSampler: source = currentInput
                case "uFrames": source = historyTexture
                case ShaderReflection.stageTexturesSampler: source = stageTextures
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

            for block in stage.reflection.uniformBlocks where block.mslBuffer >= 0 {
                let requiredLength = stage.constantBufferLength(for: block)
                switch block.name {
                case "CEContext":
                    withUnsafeBytes(of: &context) { bytes in
                        Self.setFragmentBytes(encoder, bytes: bytes, index: block.mslBuffer, requiredLength: requiredLength)
                    }
                case "Params":
                    if let paramsBuffer = stage.paramsBuffer {
                        encoder.setFragmentBuffer(paramsBuffer, offset: 0, index: block.mslBuffer)
                    }
                case ShaderReflection.stagesBlock:
                    stagesUniforms.withUnsafeBytes { bytes in
                        Self.setFragmentBytes(encoder, bytes: bytes, index: block.mslBuffer, requiredLength: requiredLength)
                    }
                case VisionUniforms.faceBlock:
                    faceSlots.withUnsafeBytes { bytes in
                        Self.setFragmentBytes(encoder, bytes: bytes, index: block.mslBuffer, requiredLength: requiredLength)
                    }
                case VisionUniforms.facePointsBlock:
                    facePointSlots.withUnsafeBytes { bytes in
                        Self.setFragmentBytes(encoder, bytes: bytes, index: block.mslBuffer, requiredLength: requiredLength)
                    }
                case VisionUniforms.handsBlock:
                    handSlots.withUnsafeBytes { bytes in
                        Self.setFragmentBytes(encoder, bytes: bytes, index: block.mslBuffer, requiredLength: requiredLength)
                    }
                default:
                    break
                }
            }

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: scratchTexture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                    to: stageTextures, destinationSlice: running.index, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }
            currentInput = stageSliceViews[running.index]
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

    /// Metal constant structs are 16-byte aligned; SPIR-V sizes often are not.
    private static func setFragmentBytes(
        _ encoder: MTLRenderCommandEncoder,
        bytes: UnsafeRawBufferPointer,
        index: Int,
        requiredLength: Int
    ) {
        guard let baseAddress = bytes.baseAddress else { return }
        let length = max(bytes.count, requiredLength)
        if length == bytes.count {
            encoder.setFragmentBytes(baseAddress, length: bytes.count, index: index)
            return
        }
        var padded = [UInt8](repeating: 0, count: length)
        padded.withUnsafeMutableBytes { dest in
            dest.copyMemory(from: UnsafeRawBufferPointer(start: baseAddress, count: min(bytes.count, length)))
        }
        padded.withUnsafeBytes { ptr in
            encoder.setFragmentBytes(ptr.baseAddress!, length: length, index: index)
        }
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

    /// std140 bytes of the `CEStages` block: two ints (padded to 16 bytes),
    /// then the `ivec4 uStageRefs[]` array, whose ivec4s pack tightly.
    private static func stagesUniformBytes(index: Int, count: Int, refs: [Int32]) -> [Int32] {
        let arrayBase = 4 // Int32 slots: the array starts at byte offset 16
        var words = [Int32](repeating: -1, count: arrayBase + ShaderCompiler.maxStageReferences)
        words[0] = Int32(index)
        words[1] = Int32(count)
        words[2] = 0
        words[3] = 0
        for (slot, ref) in refs.prefix(ShaderCompiler.maxStageReferences).enumerated() {
            words[arrayBase + slot] = ref
        }
        return words
    }

    /// Sizes `uStageTextures` to the active effect. Only that effect's stages
    /// ever occupy GPU memory; switching effects reallocates, and an effect
    /// without stages holds nothing.
    private func ensureStageTextures(count: Int) {
        guard count != allocatedStageCount || (count > 0 && (stageTextures == nil || scratchTexture == nil)) else {
            return
        }
        allocatedStageCount = count
        stageSliceViews = []
        stageTextures = nil
        scratchTexture = nil
        stageTexturesNeedClear = false
        guard count > 0 else { return }

        let scratchDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false
        )
        scratchDescriptor.usage = [.renderTarget, .shaderRead]
        scratchDescriptor.storageMode = .private
        scratchTexture = device.makeTexture(descriptor: scratchDescriptor)

        let arrayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false
        )
        arrayDescriptor.textureType = .type2DArray
        arrayDescriptor.arrayLength = count
        // Render-target usage is only needed for the one-time clear.
        arrayDescriptor.usage = [.renderTarget, .shaderRead]
        arrayDescriptor.storageMode = .private
        guard let array = device.makeTexture(descriptor: arrayDescriptor) else { return }
        stageTextures = array
        stageSliceViews = (0..<count).compactMap { slice in
            array.makeTextureView(
                pixelFormat: .bgra8Unorm, textureType: .type2D, levels: 0..<1, slices: slice..<(slice + 1)
            )
        }
        stageTexturesNeedClear = true
    }

    private func ensureResources(depth: Int) {
        guard depth != allocatedDepth || historyTexture == nil || workingTexture == nil || outputPool == nil else {
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
