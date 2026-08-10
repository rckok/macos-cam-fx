import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

/// Publishes rendered frames to the camera extension by locating the virtual
/// camera's sink stream through the CoreMediaIO C API and enqueueing sample
/// buffers into its buffer queue.
final class VirtualCameraSink: ObservableObject {

    @Published private(set) var isConnected = false

    /// Thread-safe gate checked on the frame path; toggled from the UI.
    private let enabledLock = NSLock()
    private var _enabled = false
    var enabled: Bool {
        get { enabledLock.lock(); defer { enabledLock.unlock() }; return _enabled }
        set {
            enabledLock.lock()
            _enabled = newValue
            enabledLock.unlock()
            if newValue { connect() } else { disconnect() }
        }
    }

    private let queue = DispatchQueue(label: "cameraEffects.sink")
    private var deviceID: CMIODeviceID?
    private var sinkStreamID: CMIOStreamID?
    private var bufferQueue: CMSimpleQueue?
    private var streamStarted = false
    private var formatDescription: CMFormatDescription?
    private var formatDimensions: CMVideoDimensions?

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
            DispatchQueue.main.async { self.isConnected = false }
        }
    }

    private func connectLocked() {
        guard bufferQueue == nil else { return }

        guard let deviceID = findDevice(uid: VirtualCamera.deviceUID.uuidString) else { return }
        guard let sinkStreamID = findSinkStream(deviceID: deviceID) else { return }

        var queueOut: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(
            sinkStreamID,
            { _, _, _ in
                // Queue-altered callback; nothing to do, we push opportunistically.
            },
            nil,
            &queueOut
        )
        guard status == noErr, let queueOut else { return }

        self.deviceID = deviceID
        self.sinkStreamID = sinkStreamID
        self.bufferQueue = queueOut.takeRetainedValue()

        if CMIODeviceStartStream(deviceID, sinkStreamID) == noErr {
            streamStarted = true
            DispatchQueue.main.async { self.isConnected = true }
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
            guard CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) else { return }

            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            if self.formatDescription == nil
                || self.formatDimensions?.width != width
                || self.formatDimensions?.height != height {
                var description: CMFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: pixelBuffer,
                    formatDescriptionOut: &description
                )
                self.formatDescription = description
                self.formatDimensions = CMVideoDimensions(width: width, height: height)
            }
            guard let formatDescription = self.formatDescription else { return }

            var timing = CMSampleTimingInfo(
                duration: .invalid,
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

            CMSimpleQueueEnqueue(bufferQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
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

        for deviceID in deviceIDs {
            if deviceUID(of: deviceID) == uid {
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
