import CoreMediaIO
import CoreVideo
import CoreText
import Foundation
import IOKit.audio
import os.log

let extensionLogger = Logger(subsystem: "studio.polyglot.CameraEffects.Extension", category: "provider")

// MARK: - Device source

final class CameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!

    private var _sourceStreamSource: CameraExtensionStreamSource!
    private var _sinkStreamSource: CameraExtensionSinkStreamSource!

    private let _stateQueue = DispatchQueue(label: "cameraEffects.extension.state")
    private let _timerQueue = DispatchQueue(label: "cameraEffects.extension.timer", qos: .userInteractive)

    private var _streamingCounter = 0
    private var _sinkStreaming = false
    private var _sinkClient: CMIOExtensionClient?
    private var _lastSinkFrameHostTime: UInt64 = 0

    private var _timer: DispatchSourceTimer?
    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _placeholderPhase: Double = 0

    init(localizedName: String) {
        super.init()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: VirtualCamera.deviceUID,
            legacyDeviceID: nil,
            source: self
        )

        let dims = CMVideoDimensions(width: Int32(VirtualCamera.width), height: Int32(VirtualCamera.height))
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dims.width,
            height: dims.height,
            extensions: nil,
            formatDescriptionOut: &_videoDescription
        )

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: dims.width,
            kCVPixelBufferHeightKey as String: dims.height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes as CFDictionary, &_bufferPool)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: 1),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate)),
            validFrameDurations: nil
        )

        _sourceStreamSource = CameraExtensionStreamSource(
            localizedName: "\(localizedName) Stream",
            streamID: VirtualCamera.sourceStreamUID,
            streamFormat: streamFormat,
            device: device,
            deviceSource: self
        )
        _sinkStreamSource = CameraExtensionSinkStreamSource(
            localizedName: "\(localizedName) Sink",
            streamID: VirtualCamera.sinkStreamUID,
            streamFormat: streamFormat,
            device: device,
            deviceSource: self
        )

        do {
            try device.addStream(_sourceStreamSource.stream)
            try device.addStream(_sinkStreamSource.stream)
        } catch {
            fatalError("Failed to add streams to device: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Camera Effects Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No settable properties.
    }

    // MARK: Source stream lifecycle

    func startStreaming() {
        _stateQueue.sync {
            _streamingCounter += 1
            if _timer == nil {
                startPlaceholderTimer()
            }
        }
    }

    func stopStreaming() {
        _stateQueue.sync {
            _streamingCounter = max(0, _streamingCounter - 1)
            if _streamingCounter == 0 {
                stopPlaceholderTimer()
            }
        }
    }

    // MARK: Sink stream lifecycle

    func startSinkStreaming(client: CMIOExtensionClient) {
        _stateQueue.sync {
            _sinkClient = client
            _sinkStreaming = true
        }
        consumeNextBuffer(client: client)
    }

    func stopSinkStreaming() {
        _stateQueue.sync {
            _sinkStreaming = false
            _sinkClient = nil
            _lastSinkFrameHostTime = 0
        }
    }

    private var isSinkStreaming: Bool {
        _stateQueue.sync { _sinkStreaming }
    }

    private func consumeNextBuffer(client: CMIOExtensionClient) {
        guard isSinkStreaming else { return }

        _sinkStreamSource.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMoreSampleBuffers, error in
            guard let self else { return }
            if let sampleBuffer {
                let hostTimeNs = UInt64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                self._stateQueue.sync { self._lastSinkFrameHostTime = hostTimeNs }
                if self._stateQueue.sync(execute: { self._streamingCounter > 0 }) {
                    self._sourceStreamSource.stream.send(
                        sampleBuffer,
                        discontinuity: discontinuity,
                        hostTimeInNanoseconds: hostTimeNs
                    )
                }
                self._sinkStreamSource.notifyConsumed()
            }
            if let error {
                extensionLogger.error("consumeSampleBuffer error: \(error.localizedDescription, privacy: .public)")
            }
            // Keep pulling as long as the sink client is streaming.
            self.consumeNextBuffer(client: client)
        }
    }

    // MARK: Placeholder frames

    /// Emits a placeholder card whenever no sink client has delivered a frame
    /// recently, so the virtual camera always produces output.
    private func startPlaceholderTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(VirtualCamera.frameRate), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let nowNs = UInt64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            let lastSink = self._stateQueue.sync { self._lastSinkFrameHostTime }
            // If the app delivered a frame within the last half second, stay quiet.
            if lastSink != 0, nowNs &- lastSink < 500_000_000 { return }
            self.emitPlaceholderFrame(hostTimeNs: nowNs)
        }
        timer.resume()
        _timer = timer
    }

    private func stopPlaceholderTimer() {
        _timer?.cancel()
        _timer = nil
    }

    private func emitPlaceholderFrame(hostTimeNs: UInt64) {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bufferPool, &pixelBuffer)
        guard let pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        drawPlaceholder(into: pixelBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: _videoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if let sampleBuffer {
            _sourceStreamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTimeNs)
        }
    }

    private func drawPlaceholder(into pixelBuffer: CVPixelBuffer) {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        _placeholderPhase += 0.01
        let pulse = 0.5 + 0.15 * sin(_placeholderPhase)

        // Dark gradient background with a subtle pulse.
        let colors = [
            CGColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1),
            CGColor(red: 0.12 * pulse + 0.05, green: 0.10, blue: 0.22, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: height),
                options: []
            )
        }

        // Centered label drawn with CoreText (no AppKit in the extension).
        let text = "Camera Effects\nOpen the app to start streaming"
        var alignment = CTTextAlignment.center
        let paragraphStyle = withUnsafeBytes(of: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer.baseAddress!
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.85, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: attributed.length), nil,
            CGSize(width: CGFloat(width) * 0.8, height: CGFloat(height)), nil
        )
        let textRect = CGRect(
            x: (CGFloat(width) - textSize.width) / 2,
            y: (CGFloat(height) - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
    }
}

// MARK: - Source stream (what video-call apps see)

final class CameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat
    private weak var _deviceSource: CameraExtensionDeviceSource?

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice,
        deviceSource: CameraExtensionDeviceSource
    ) {
        self.device = device
        self._streamFormat = streamFormat
        self._deviceSource = deviceSource
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                extensionLogger.error("Invalid format index requested")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        _deviceSource?.startStreaming()
    }

    func stopStream() throws {
        _deviceSource?.stopStreaming()
    }
}

// MARK: - Sink stream (fed by the main app)

final class CameraExtensionSinkStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat
    private weak var _deviceSource: CameraExtensionDeviceSource?
    private var _client: CMIOExtensionClient?
    private var _consumedCount: UInt64 = 0

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice,
        deviceSource: CameraExtensionDeviceSource
    ) {
        self.device = device
        self._streamFormat = streamFormat
        self._deviceSource = deviceSource
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount,
            .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 8
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // No settable properties.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        _client = client
        return true
    }

    func startStream() throws {
        guard let client = _client else {
            throw NSError(domain: "studio.polyglot.CameraEffects.Extension", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No authorized sink client"
            ])
        }
        _deviceSource?.startSinkStreaming(client: client)
    }

    func stopStream() throws {
        _deviceSource?.stopSinkStreaming()
    }

    func notifyConsumed() {
        _consumedCount += 1
    }
}

// MARK: - Provider source

final class CameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraExtensionDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraExtensionDeviceSource(localizedName: VirtualCamera.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Camera Effects"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable properties.
    }
}
