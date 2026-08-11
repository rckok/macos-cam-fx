import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os.log

private let sinkLogger = Logger(subsystem: "studio.polyglot.CameraEffects", category: "sink")

/// Publishes rendered frames to the camera extension by locating the virtual
/// camera's sink stream through the CoreMediaIO C API and enqueueing sample
/// buffers into its buffer queue.
final class VirtualCameraSink: ObservableObject {

    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    /// Thread-safe gate checked on the frame path; toggled from the UI.
    private let enabledLock = NSLock()
    private var _enabled = false
    var enabled: Bool {
        get { enabledLock.lock(); defer { enabledLock.unlock() }; return _enabled }
        set {
            enabledLock.lock()
            _enabled = newValue
            enabledLock.unlock()
            if newValue {
                connect()
                startReconnectTimer()
            } else {
                stopReconnectTimer()
                disconnect()
            }
        }
    }

    private let queue = DispatchQueue(label: "cameraEffects.sink")
    private var deviceID: CMIODeviceID?
    private var sinkStreamID: CMIOStreamID?
    private var bufferQueue: CMSimpleQueue?
    private var streamStarted = false
    private var formatDescription: CMFormatDescription?
    private var reconnectTimer: DispatchSourceTimer?
    private var framesEnqueued: UInt64 = 0

    // MARK: Connection

    /// Attempts to find the extension's device and open its sink stream.
    /// Safe to call repeatedly; retries until the extension is installed.
    func connect() {
        queue.async { [weak self] in
            self?.connectLocked()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            if let deviceID = self.deviceID, let streamID = self.sinkStreamID, self.streamStarted {
                CMIODeviceStopStream(deviceID, streamID)
            }
            self.streamStarted = false
            self.bufferQueue = nil
            self.sinkStreamID = nil
            self.deviceID = nil
            self.formatDescription = nil
            DispatchQueue.main.async {
                self.isConnected = false
            }
        }
    }

    private func startReconnectTimer() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reconnectTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
            timer.setEventHandler { [weak self] in
                guard let self, self.enabled, self.bufferQueue == nil else { return }
                self.connectLocked()
            }
            timer.resume()
            self.reconnectTimer = timer
        }
    }

    private func stopReconnectTimer() {
        queue.async { [weak self] in
            self?.reconnectTimer?.cancel()
            self?.reconnectTimer = nil
        }
    }

    private func connectLocked() {
        guard bufferQueue == nil else { return }

        guard let deviceID = findDevice(uid: VirtualCamera.deviceUID.uuidString) else {
            setError("Virtual camera device not found — is the extension installed and approved?")
            return
        }
        guard let sinkStreamID = findSinkStream(deviceID: deviceID) else {
            setError("Virtual camera sink stream not found")
            return
        }

        var queueOut: Unmanaged<CMSimpleQueue>?
        let queueStatus = CMIOStreamCopyBufferQueue(
            sinkStreamID,
            { _, _, _ in },
            nil,
            &queueOut
        )
        guard queueStatus == noErr, let queueOut else {
            setError("Failed to open sink buffer queue (status \(queueStatus))")
            return
        }

        self.deviceID = deviceID
        self.sinkStreamID = sinkStreamID
        self.bufferQueue = queueOut.takeRetainedValue()

        let startStatus = CMIODeviceStartStream(deviceID, sinkStreamID)
        guard startStatus == noErr else {
            self.bufferQueue = nil
            self.sinkStreamID = nil
            self.deviceID = nil
            setError("Failed to start sink stream (status \(startStatus))")
            return
        }

        streamStarted = true
        framesEnqueued = 0
        sinkLogger.info("Connected to virtual camera sink stream")
        DispatchQueue.main.async {
            self.isConnected = true
            self.lastError = nil
        }
    }

    private func setError(_ message: String) {
        sinkLogger.error("\(message, privacy: .public)")
        DispatchQueue.main.async {
            self.lastError = message
            self.isConnected = false
        }
    }

    // MARK: Frame delivery

    /// Enqueues one rendered frame. Called from a Metal completion handler.
    func send(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard enabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.bufferQueue == nil {
                self.connectLocked()
            }
            guard let bufferQueue = self.bufferQueue else { return }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width == VirtualCamera.width, height == VirtualCamera.height else {
                // Drop mismatched frames rather than poison the sink stream.
                sinkLogger.error("Dropping frame with unexpected size \(width)x\(height)")
                return
            }

            let capacity = CMSimpleQueueGetCapacity(bufferQueue)
            let count = CMSimpleQueueGetCount(bufferQueue)
            guard count < capacity else { return }

            if self.formatDescription == nil {
                var description: CMFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: pixelBuffer,
                    formatDescriptionOut: &description
                )
                self.formatDescription = description
            }
            guard let formatDescription = self.formatDescription else { return }

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate)),
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer else { return }

            let enqueueStatus = CMSimpleQueueEnqueue(bufferQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
            if enqueueStatus == noErr {
                self.framesEnqueued += 1
            } else {
                // Balance the retain from passRetained if enqueue failed.
                Unmanaged<CMSampleBuffer>.passUnretained(sampleBuffer).release()
                sinkLogger.error("CMSimpleQueueEnqueue failed: \(enqueueStatus)")
            }
        }
    }

    // MARK: CMIO object graph lookup

    private func propertyAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private func findDevice(uid: String) -> CMIODeviceID? {
        var address = propertyAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &dataUsed, &deviceIDs
        ) == noErr else { return nil }

        let target = uid.uppercased()
        for deviceID in deviceIDs {
            if let found = deviceUID(of: deviceID), found.uppercased() == target {
                return deviceID
            }
        }
        return nil
    }

    private func deviceUID(of deviceID: CMIODeviceID) -> String? {
        var address = propertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return nil }

        var uid: CFString = "" as CFString
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            CMIOObjectGetPropertyData(deviceID, &address, 0, nil, dataSize, &dataUsed, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    private func findSinkStream(deviceID: CMIODeviceID) -> CMIOStreamID? {
        var address = propertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIDs = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            deviceID, &address, 0, nil, dataSize, &dataUsed, &streamIDs
        ) == noErr else { return nil }

        // The sink stream has direction 1 (host -> device).
        for streamID in streamIDs {
            var directionAddress = propertyAddress(CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
            var direction: UInt32 = 0
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(streamID, &directionAddress, 0, nil, size, &used, &direction) == noErr,
               direction == 1 {
                return streamID
            }
        }
        // Fallback: providers commonly expose [source, sink] in that order.
        return streamIDs.count > 1 ? streamIDs[1] : nil
    }
}
