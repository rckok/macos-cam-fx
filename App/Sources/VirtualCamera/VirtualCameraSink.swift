import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os.log

private let sinkLogger = Logger(subsystem: "studio.polyglot.CameraEffects", category: "sink")

/// C callback invoked when the extension finishes consuming a sink buffer.
private func sinkScheduledOutputProc(
    sequenceNumber: UInt64,
    outputHostTime: UInt64,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let sink = Unmanaged<VirtualCameraSink>.fromOpaque(refcon).takeUnretainedValue()
    sink.markReadyToEnqueue()
}

/// C callback invoked when the sink stream's CMSimpleQueue is altered (space available).
private func sinkQueueAlteredProc(
    streamID: CMIOStreamID,
    token: UnsafeMutableRawPointer?,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let sink = Unmanaged<VirtualCameraSink>.fromOpaque(refcon).takeUnretainedValue()
    sink.markReadyToEnqueue()
}

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
    private var nextSequenceNumber: UInt64 = 0
    private var readyToEnqueue = false

    init() {
        Self.enableVirtualCameraDevices()
    }

    fileprivate func markReadyToEnqueue() {
        queue.async { [weak self] in
            self?.readyToEnqueue = true
        }
    }

    // MARK: Connection

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
            self.readyToEnqueue = false
            self.nextSequenceNumber = 0
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

        guard let deviceID = findDevice() else {
            setError("Virtual camera device not found — is the extension installed and approved?")
            return
        }
        guard let sinkStreamID = findSinkStream(deviceID: deviceID) else {
            setError("Virtual camera sink stream not found")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var queueOut: Unmanaged<CMSimpleQueue>?
        let queueStatus = CMIOStreamCopyBufferQueue(
            sinkStreamID,
            sinkQueueAlteredProc,
            refcon,
            &queueOut
        )
        guard queueStatus == noErr, let queueOut else {
            setError("Failed to open sink buffer queue (status \(queueStatus))")
            return
        }

        var procAndRefCon = CMIOStreamScheduledOutputNotificationProcAndRefCon(
            scheduledOutputNotificationProc: sinkScheduledOutputProc,
            scheduledOutputNotificationRefCon: refcon
        )
        var sonpAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyScheduledOutputNotificationProc),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let sonpStatus = CMIOObjectSetPropertyData(
            sinkStreamID,
            &sonpAddress,
            0,
            nil,
            UInt32(MemoryLayout<CMIOStreamScheduledOutputNotificationProcAndRefCon>.size),
            &procAndRefCon
        )
        guard sonpStatus == noErr else {
            setError("Failed to register sink output callback (status \(sonpStatus))")
            return
        }

        self.deviceID = deviceID
        self.sinkStreamID = sinkStreamID
        self.bufferQueue = queueOut.takeUnretainedValue()

        let startStatus = CMIODeviceStartStream(deviceID, sinkStreamID)
        guard startStatus == noErr else {
            self.bufferQueue = nil
            self.sinkStreamID = nil
            self.deviceID = nil
            setError("Failed to start sink stream (status \(startStatus))")
            return
        }

        streamStarted = true
        nextSequenceNumber = 0
        readyToEnqueue = true
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

    func send(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard enabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.bufferQueue == nil {
                self.connectLocked()
            }
            guard self.bufferQueue != nil else { return }
            guard self.readyToEnqueue else { return }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width == VirtualCamera.width, height == VirtualCamera.height else {
                sinkLogger.error("Dropping frame with unexpected size \(width)x\(height)")
                return
            }

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
            let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            guard createStatus == noErr, let sampleBuffer else { return }

            // CMIO sink streams require monotonically increasing sequence numbers.
            CMIOSampleBufferSetSequenceNumber(
                kCFAllocatorDefault,
                sampleBuffer,
                self.nextSequenceNumber
            )
            self.nextSequenceNumber &+= 1

            guard let bufferQueue = self.bufferQueue else { return }
            let enqueueStatus = CMSimpleQueueEnqueue(
                bufferQueue,
                element: Unmanaged.passRetained(sampleBuffer).toOpaque()
            )
            if enqueueStatus == noErr {
                self.readyToEnqueue = false
            } else {
                Unmanaged<CMSampleBuffer>.passUnretained(sampleBuffer).release()
                sinkLogger.error("CMSimpleQueueEnqueue failed: \(enqueueStatus)")
            }
        }
    }

    // MARK: CMIO object graph lookup

    private static func enableVirtualCameraDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    /// Finds the virtual camera CMIO device by matching the AVFoundation device UID.
    private func findDevice() -> CMIODeviceID? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        guard let avDevice = discovery.devices.first(where: { $0.localizedName == VirtualCamera.deviceName }) else {
            // Fall back to the fixed UUID from our extension manifest.
            return findDevice(uid: VirtualCamera.deviceUID.uuidString)
        }
        return findDevice(uid: avDevice.uniqueID)
    }

    private func findDevice(uid: String) -> CMIODeviceID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
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
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
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

    /// The sink stream is always the second stream (source first, sink second).
    private func findSinkStream(deviceID: CMIODeviceID) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIDs = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            deviceID, &address, 0, nil, dataSize, &dataUsed, &streamIDs
        ) == noErr else { return nil }

        guard streamIDs.count >= 2 else { return nil }
        return streamIDs[1]
    }
}
