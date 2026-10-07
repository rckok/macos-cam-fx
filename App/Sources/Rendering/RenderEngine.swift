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

    /// Layout of `CEBackgroundUniforms` in `BuiltinShaders`: a float4, then a
    /// float padded out to the struct's 16-byte alignment.
    private struct BackgroundUniforms {
        /// xy = scale, zw = offset applied to vUV to aspect-fill the image.
        var backgroundUV: SIMD4<Float>
        var mirror: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!
    let vertexFunction: MTLFunction
    private let blitPipeline: MTLRenderPipelineState
    private let flipHPipeline: MTLRenderPipelineState
    private let blitR8Pipeline: MTLRenderPipelineState
    private let flipHR8Pipeline: MTLRenderPipelineState
    private let backgroundCompositePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    /// For `uState`: 32-bit float textures are not filterable on every GPU,
    /// and `ceState` reads exact texels anyway.
    private let stateSampler: MTLSamplerState

    private let visionProcessor: VisionProcessor
    private let handMaskRenderer: HandMaskRenderer
    /// 1x1 zero textures bound when a vision result is not available yet.
    private let fallbackMaskTexture: MTLTexture
    private let fallbackRGBATexture: MTLTexture
    /// Bound as `uState` for geometry stages without a simulation pass.
    private let fallbackStateTexture: MTLTexture

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "cameraEffects.render", qos: .userInteractive)

    // Protected by `lock`:
    private var stages: [RunningStage] = []
    /// Stages in the active effect, rendered or not; sizes `uStageTextures`.
    private var stageCount: Int = 0
    private var historyDepth: Int = 16
    private var flipHorizontal: Bool = true
    /// Set by `restart()`, consumed by the next frame.
    private var restartRequested = false
    /// What the active effect's shaders read, per reflection.
    private var stageVisionFeatures: VisionFeatures = []
    /// `stageVisionFeatures` plus the person matte while a background is set.
    private var visionFeatures: VisionFeatures = []
    /// The image composited under the person in place of the camera frame's
    /// own background, or nil to pass the camera through.
    private var backgroundTexture: MTLTexture?
    /// The selected camera is suspended. Frames already queued must not
    /// replace the cleared preview with the white image those cameras emit.
    /// Protected by `lock`.
    private var inputSuspended = false

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
    /// Simulation state of the active effect's geometry stages, by stage ID.
    private var simulationStates: [String: SimulationState] = [:]

    /// Latest fully rendered output texture, for the preview view. Written on
    /// the render queue and read on the main thread, so the reference itself
    /// is handed over under `lock`: a strong-reference swap is not atomic, and
    /// a read overlapping the release of the previous texture is a crash.
    var previewTexture: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return latestOutputTexture
    }
    // Protected by `lock`:
    private var latestOutputTexture: MTLTexture?

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
              let backgroundFragment = library.makeFunction(name: "ce_background_composite_fragment"),
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
        self.backgroundCompositePipeline = try makePipeline(backgroundFragment, .bgra8Unorm)

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

        let stateDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false
        )
        stateDescriptor.textureType = .type2DArray
        stateDescriptor.arrayLength = 1
        stateDescriptor.usage = [.shaderRead]
        guard let fallbackState = device.makeTexture(descriptor: stateDescriptor) else {
            throw NSError(domain: "CameraEffects", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create fallback texture"])
        }
        var zeroState = [Float](repeating: 0, count: 4)
        fallbackState.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0,
            withBytes: &zeroState, bytesPerRow: 16, bytesPerImage: 16
        )
        self.fallbackStateTexture = fallbackState

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

        let stateSamplerDescriptor = MTLSamplerDescriptor()
        stateSamplerDescriptor.minFilter = .nearest
        stateSamplerDescriptor.magFilter = .nearest
        stateSamplerDescriptor.sAddressMode = .clampToEdge
        stateSamplerDescriptor.tAddressMode = .clampToEdge
        guard let stateSampler = device.makeSamplerState(descriptor: stateSamplerDescriptor) else {
            throw NSError(domain: "CameraEffects", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create sampler"])
        }
        self.stateSampler = stateSampler
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
        stageVisionFeatures = features
        lock.unlock()
        updateVisionFeatures()
    }

    /// The image to put behind the person, aspect-filled to the output, or
    /// nil to leave the camera frame as it is. Setting one turns person
    /// segmentation on whether or not any stage samples `uPersonMatte`.
    func setBackground(_ texture: MTLTexture?) {
        lock.lock()
        backgroundTexture = texture
        lock.unlock()
        updateVisionFeatures()
    }

    /// Segmentation level for every use of the person matte — the background
    /// composite and stages sampling `uPersonMatte` alike.
    func setPersonMatteQuality(_ quality: PersonMatteQuality) {
        visionProcessor.setMatteQuality(quality)
    }

    private func updateVisionFeatures() {
        lock.lock()
        var features = stageVisionFeatures
        if backgroundTexture != nil {
            features.insert(.personMatte)
        }
        visionFeatures = features
        lock.unlock()
        visionProcessor.setFeatures(features)
    }

    func setHistoryDepth(_ depth: Int) {
        lock.lock()
        historyDepth = max(1, min(depth, 120))
        lock.unlock()
    }

    /// Starts the active effect over on the next frame: `uTime` and
    /// `uFrameNumber` from 0, stage textures (feedback) transparent again and
    /// every simulation from zeroed state. Effects share one clock, so this
    /// holds for whichever effect is switched to afterwards too.
    func restart() {
        lock.lock()
        restartRequested = true
        lock.unlock()
    }

    func setFlipHorizontal(_ flip: Bool) {
        lock.lock()
        flipHorizontal = flip
        lock.unlock()
    }

    /// Drops the preview while the selected camera is suspended, and ignores
    /// frames that were already queued so a white frame cannot land afterwards.
    func setInputSuspended(_ suspended: Bool) {
        lock.lock()
        inputSuspended = suspended
        if suspended {
            latestOutputTexture = nil
        }
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
        if inputSuspended {
            lock.unlock()
            return
        }
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
        let background = backgroundTexture
        let restart = restartRequested
        restartRequested = false
        lock.unlock()

        if restart {
            startTime = nil
            lastFrameTime = nil
            frameNumber = 0
            simulationStates.removeAll()
            stageTexturesNeedClear = true
        }

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
        //    resolution that matches the virtual camera. With a background set,
        //    this is where it goes under the person: everything downstream —
        //    the history ring, uPrev, the preview — sees the composited frame
        //    as the camera. Until the first matte arrives the frame passes
        //    through as is.
        if let background, let matte = vision.personMatte {
            encodeBackgroundComposite(
                commandBuffer: commandBuffer,
                camera: frameTexture,
                background: background,
                matte: matte,
                mirrored: mirrored,
                destination: workingTexture
            )
        } else {
            encodeBlit(
                commandBuffer: commandBuffer,
                pipeline: mirrored ? flipHPipeline : blitPipeline,
                source: frameTexture,
                destination: workingTexture
            )
        }

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
        let bodySlots = VisionUniformPacking.packBodies(vision.bodies)

        // 4. Timing / context uniforms.
        let now = CACurrentMediaTime()
        if startTime == nil { startTime = now }
        let context = ContextUniforms(
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
        var simulatedStageIDs = Set<String>()
        for running in currentStages {
            guard let scratchTexture, let stageTextures,
                  stageSliceViews.indices.contains(running.index)
            else { continue }
            running.textureAssets.advanceVideoFrames()

            let stage = running.compiled
            let frame = FrameResources(
                context: context,
                historyTexture: historyTexture,
                stageTextures: stageTextures,
                vision: vision,
                activeVision: activeVision,
                faceSlots: faceSlots,
                facePointSlots: facePointSlots,
                handSlots: handSlots,
                bodySlots: bodySlots,
                stagesUniforms: Self.stagesUniformBytes(
                    index: running.index, count: currentStageCount, refs: running.stageRefs
                )
            )

            // Geometry stages: advance the simulation, then draw from its
            // latest state.
            var stateTexture: MTLTexture?
            var geometryUniforms: [Int32]?
            if let geometry = running.geometry {
                var simulation: SimulationState?
                if let pipeline = stage.simulationPipeline, let bindings = stage.simulationBindings,
                   let state = simulationState(for: running, slots: stage.stateSlots, commandBuffer: commandBuffer) {
                    simulatedStageIDs.insert(running.stageID)
                    for substep in 0..<geometry.substeps.clamped(to: GeometrySettings.substepRange) {
                        encodeSimulationStep(
                            commandBuffer: commandBuffer,
                            pipeline: pipeline,
                            bindings: bindings,
                            state: state,
                            running: running,
                            frame: frame,
                            previous: currentInput,
                            geometryUniforms: Self.geometryUniformBytes(
                                geometry: geometry, state: state, substep: substep, timeDelta: context.timeDelta
                            )
                        )
                    }
                    simulation = state
                    stateTexture = state.latest
                }
                geometryUniforms = Self.geometryUniformBytes(
                    geometry: geometry, state: simulation, substep: 0, timeDelta: context.timeDelta
                )
                simulation?.frame &+= 1
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = scratchTexture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let geometry = running.geometry {
                // Geometry only covers part of the frame; the rest keeps what
                // the stage starts from.
                switch geometry.startFrom {
                case .transparent:
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                case .previousStage:
                    encodeCopy(commandBuffer: commandBuffer, from: currentInput, to: scratchTexture)
                    pass.colorAttachments[0].loadAction = .load
                case .ownLastFrame:
                    encodeCopy(commandBuffer: commandBuffer, from: stageSliceViews[running.index], to: scratchTexture)
                    pass.colorAttachments[0].loadAction = .load
                }
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setRenderPipelineState(stage.pipeline)
            if let vertexBindings = stage.vertexBindings {
                bind(
                    vertexBindings, as: .vertex, encoder: encoder, running: running, frame: frame,
                    previous: currentInput, geometryUniforms: geometryUniforms, state: stateTexture
                )
            }
            bind(
                stage.fragmentBindings, as: .fragment, encoder: encoder, running: running, frame: frame,
                previous: currentInput, geometryUniforms: geometryUniforms, state: stateTexture
            )
            if let geometry = running.geometry {
                encoder.drawPrimitives(
                    type: geometry.primitive.metalPrimitive,
                    vertexStart: 0,
                    vertexCount: geometry.verticesPerItem,
                    instanceCount: geometry.count
                )
            } else {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()

            encodeCopy(commandBuffer: commandBuffer, from: scratchTexture, to: stageTextures, slice: running.index)
            currentInput = stageSliceViews[running.index]
        }
        // State belongs to the stages that just ran; anything else was
        // removed, switched off or is no longer in the active effect.
        simulationStates = simulationStates.filter { simulatedStageIDs.contains($0.key) }

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

        lock.lock()
        // Suspension can flip while this frame is encoding. Publishing it
        // would put the white image back up after the preview was cleared.
        if inputSuspended {
            latestOutputTexture = nil
        } else {
            latestOutputTexture = currentInput
        }
        let publish = !inputSuspended
        lock.unlock()
        if publish {
            commandBuffer.commit()
        }
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

    /// `mix(background, camera, matte)` into `destination`. The camera and the
    /// raw Vision matte are in the same orientation, so both take the mirrored
    /// UV; the background is aspect-filled and never mirrored, so the picture
    /// reads the way it was chosen whatever the mirror setting does to the feed.
    private func encodeBackgroundComposite(
        commandBuffer: MTLCommandBuffer,
        camera: MTLTexture,
        background: MTLTexture,
        matte: MTLTexture,
        mirrored: Bool,
        destination: MTLTexture
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = BackgroundUniforms(
            backgroundUV: Self.aspectFillTransform(
                imageWidth: background.width, imageHeight: background.height,
                targetWidth: outputWidth, targetHeight: outputHeight
            ),
            mirror: mirrored ? 1 : 0
        )
        encoder.setRenderPipelineState(backgroundCompositePipeline)
        encoder.setFragmentTexture(camera, index: 0)
        encoder.setFragmentTexture(background, index: 1)
        encoder.setFragmentTexture(matte, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BackgroundUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// UV scale (xy) and offset (zw) that crop an image to cover the target
    /// while keeping its aspect ratio, centered.
    private static func aspectFillTransform(
        imageWidth: Int, imageHeight: Int, targetWidth: Int, targetHeight: Int
    ) -> SIMD4<Float> {
        guard imageWidth > 0, imageHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return SIMD4<Float>(1, 1, 0, 0)
        }
        let imageAspect = Float(imageWidth) / Float(imageHeight)
        let targetAspect = Float(targetWidth) / Float(targetHeight)
        var scale = SIMD2<Float>(1, 1)
        if imageAspect > targetAspect {
            // Wider than the target: crop the sides.
            scale.x = targetAspect / imageAspect
        } else {
            // Taller than the target: crop top and bottom.
            scale.y = imageAspect / targetAspect
        }
        let offset = (SIMD2<Float>(1, 1) - scale) * 0.5
        return SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)
    }

    // MARK: Stage passes

    /// What every stage function of one stage may bind this frame.
    private struct FrameResources {
        let context: ContextUniforms
        let historyTexture: MTLTexture
        let stageTextures: MTLTexture
        let vision: VisionSnapshot
        let activeVision: VisionFeatures
        let faceSlots: [SIMD4<Float>]
        let facePointSlots: [SIMD4<Float>]
        let handSlots: [SIMD4<Float>]
        let bodySlots: [SIMD4<Float>]
        let stagesUniforms: [Int32]
    }

    private enum FunctionStage {
        case vertex
        case fragment
    }

    /// A geometry stage's simulation state: two texture arrays with one
    /// 32-bit float slice per slot, written alternately so a step never reads
    /// the texture it writes.
    private final class SimulationState {
        let count: Int
        let slots: Int
        let width: Int
        let height: Int
        let resetCount: Int
        let textures: [MTLTexture]
        /// Index into `textures` of the latest completed step.
        var current = 0
        /// Frames simulated since the state was created.
        var frame: Int32 = 0

        var latest: MTLTexture { textures[current] }

        /// The smallest near-square texture with a texel per item.
        init?(device: MTLDevice, count: Int, slots: Int, resetCount: Int) {
            let width = max(1, Int(Double(count).squareRoot().rounded(.up)))
            let height = max(1, (count + width - 1) / width)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
            )
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = slots
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let first = device.makeTexture(descriptor: descriptor),
                  let second = device.makeTexture(descriptor: descriptor)
            else { return nil }
            self.count = count
            self.slots = slots
            self.width = width
            self.height = height
            self.resetCount = resetCount
            self.textures = [first, second]
        }
    }

    /// The stage's state, created zeroed when it has none yet or when its
    /// item count, slot count or reset counter changed.
    private func simulationState(for running: RunningStage, slots: Int, commandBuffer: MTLCommandBuffer) -> SimulationState? {
        guard let geometry = running.geometry, slots > 0 else { return nil }
        if let existing = simulationStates[running.stageID],
           existing.count == geometry.count,
           existing.slots == slots,
           existing.resetCount == running.simulationResetCount {
            return existing
        }
        guard let state = SimulationState(
            device: device, count: geometry.count, slots: slots, resetCount: running.simulationResetCount
        ) else {
            simulationStates[running.stageID] = nil
            return nil
        }
        for texture in state.textures {
            let pass = MTLRenderPassDescriptor()
            for slot in 0..<slots {
                pass.colorAttachments[slot].texture = texture
                pass.colorAttachments[slot].slice = slot
                pass.colorAttachments[slot].loadAction = .clear
                pass.colorAttachments[slot].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[slot].storeAction = .store
            }
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        simulationStates[running.stageID] = state
        return state
    }

    /// One step: every item's texel of every slot, read from the latest state
    /// and written to the other texture, which then becomes the latest.
    private func encodeSimulationStep(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        bindings: ShaderFunctionBindings,
        state: SimulationState,
        running: RunningStage,
        frame: FrameResources,
        previous: MTLTexture,
        geometryUniforms: [Int32]
    ) {
        let target = state.textures[1 - state.current]
        let pass = MTLRenderPassDescriptor()
        for slot in 0..<state.slots {
            pass.colorAttachments[slot].texture = target
            pass.colorAttachments[slot].slice = slot
            pass.colorAttachments[slot].loadAction = .dontCare
            pass.colorAttachments[slot].storeAction = .store
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        bind(
            bindings, as: .fragment, encoder: encoder, running: running, frame: frame,
            previous: previous, geometryUniforms: geometryUniforms, state: state.latest
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        state.current = 1 - state.current
    }

    /// std140 bytes of the `CEGeometry` block: six ints, an ivec2, a float,
    /// padded to 48 bytes.
    private static func geometryUniformBytes(
        geometry: GeometrySettings,
        state: SimulationState?,
        substep: Int,
        timeDelta: Float
    ) -> [Int32] {
        let substeps = geometry.substeps.clamped(to: GeometrySettings.substepRange)
        let simDelta = timeDelta / Float(substeps)
        return [
            Int32(clamping: geometry.count),
            Int32(clamping: geometry.verticesPerItem),
            state?.frame ?? 0,
            Int32(substep),
            Int32(substeps),
            Int32(state?.slots ?? 0),
            Int32(state?.width ?? 0),
            Int32(state?.height ?? 0),
            Int32(bitPattern: simDelta.bitPattern),
            0, 0, 0,
        ]
    }

    /// Binds what `bindings` reflects to one function of the current pipeline.
    private func bind(
        _ bindings: ShaderFunctionBindings,
        as function: FunctionStage,
        encoder: MTLRenderCommandEncoder,
        running: RunningStage,
        frame: FrameResources,
        previous: MTLTexture,
        geometryUniforms: [Int32]?,
        state: MTLTexture?
    ) {
        func setTexture(_ texture: MTLTexture, at index: Int) {
            switch function {
            case .vertex: encoder.setVertexTexture(texture, index: index)
            case .fragment: encoder.setFragmentTexture(texture, index: index)
            }
        }
        func setSampler(_ sampler: MTLSamplerState, at index: Int) {
            switch function {
            case .vertex: encoder.setVertexSamplerState(sampler, index: index)
            case .fragment: encoder.setFragmentSamplerState(sampler, index: index)
            }
        }
        func setBuffer(_ buffer: MTLBuffer, at index: Int) {
            switch function {
            case .vertex: encoder.setVertexBuffer(buffer, offset: 0, index: index)
            case .fragment: encoder.setFragmentBuffer(buffer, offset: 0, index: index)
            }
        }
        func setBytes<T>(_ values: [T], for block: ShaderReflection.UniformBlock) {
            values.withUnsafeBytes { bytes in
                Self.setBytes(
                    encoder, function: function, bytes: bytes, index: block.mslBuffer,
                    requiredLength: bindings.constantBufferLength(for: block)
                )
            }
        }

        let vision = frame.vision
        for texture in bindings.reflection.textures {
            let source: MTLTexture?
            var textureSampler = sampler
            switch texture.name {
            case ShaderReflection.previousOutputSampler: source = previous
            case "uFrames": source = frame.historyTexture
            case ShaderReflection.stageTexturesSampler: source = frame.stageTextures
            case ShaderReflection.stateSampler:
                source = state ?? fallbackStateTexture
                textureSampler = stateSampler
            case VisionUniforms.personMatteSampler:
                source = (personMatteValid ? personMatteTexture : nil) ?? fallbackMaskTexture
            case VisionUniforms.faceMaskSampler:
                source = vision.faceMask ?? fallbackRGBATexture
            case VisionUniforms.handMaskSampler:
                source = (frame.activeVision.contains(.handMask) ? handMaskTexture : nil) ?? fallbackMaskTexture
            default: source = running.textureAssets.texture(named: texture.name)
            }
            if let source, texture.mslTexture >= 0 {
                setTexture(source, at: texture.mslTexture)
            }
            if texture.mslSampler >= 0 {
                setSampler(textureSampler, at: texture.mslSampler)
            }
        }

        for block in bindings.reflection.uniformBlocks where block.mslBuffer >= 0 {
            switch block.name {
            case "CEContext":
                setBytes([frame.context], for: block)
            case "Params":
                if let paramsBuffer = bindings.paramsBuffer {
                    setBuffer(paramsBuffer, at: block.mslBuffer)
                }
            case ShaderReflection.stagesBlock:
                setBytes(frame.stagesUniforms, for: block)
            case ShaderReflection.geometryBlock:
                setBytes(geometryUniforms ?? [Int32](repeating: 0, count: 12), for: block)
            case VisionUniforms.faceBlock:
                setBytes(frame.faceSlots, for: block)
            case VisionUniforms.facePointsBlock:
                setBytes(frame.facePointSlots, for: block)
            case VisionUniforms.handsBlock:
                setBytes(frame.handSlots, for: block)
            case VisionUniforms.bodiesBlock:
                setBytes(frame.bodySlots, for: block)
            default:
                break
            }
        }
    }

    /// Copies all of `source` into `destination` (or one of its slices); both
    /// are output-sized `bgra8Unorm`.
    private func encodeCopy(commandBuffer: MTLCommandBuffer, from source: MTLTexture, to destination: MTLTexture, slice: Int = 0) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
            to: destination, destinationSlice: slice, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    /// Metal constant structs are 16-byte aligned; SPIR-V sizes often are not.
    private static func setBytes(
        _ encoder: MTLRenderCommandEncoder,
        function: FunctionStage,
        bytes: UnsafeRawBufferPointer,
        index: Int,
        requiredLength: Int
    ) {
        guard let baseAddress = bytes.baseAddress else { return }
        func set(_ pointer: UnsafeRawPointer, length: Int) {
            switch function {
            case .vertex: encoder.setVertexBytes(pointer, length: length, index: index)
            case .fragment: encoder.setFragmentBytes(pointer, length: length, index: index)
            }
        }
        let length = max(bytes.count, requiredLength)
        if length == bytes.count {
            set(baseAddress, length: length)
            return
        }
        var padded = [UInt8](repeating: 0, count: length)
        padded.withUnsafeMutableBytes { dest in
            dest.copyMemory(from: UnsafeRawBufferPointer(start: baseAddress, count: min(bytes.count, length)))
        }
        padded.withUnsafeBytes { ptr in
            set(ptr.baseAddress!, length: length)
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

private extension GeometryPrimitive {
    var metalPrimitive: MTLPrimitiveType {
        switch self {
        case .points: return .point
        case .lines: return .line
        case .lineStrip: return .lineStrip
        case .triangles: return .triangle
        case .triangleStrip: return .triangleStrip
        }
    }
}
