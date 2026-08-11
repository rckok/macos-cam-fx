import AVFoundation
import Combine
import CoreVideo
import Foundation

/// Captures frames from a selectable camera device and delivers BGRA pixel
/// buffers to a frame handler on a dedicated capture queue.
final class CaptureManager: NSObject, ObservableObject {

    struct Device: Identifiable, Hashable {
        let id: String // uniqueID
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var authorizationDenied = false
    @Published var selectedDeviceID: String? {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            reconfigureSession()
        }
    }

    /// Called on the capture queue for every captured frame.
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "cameraEffects.capture", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var discoveryObservation: NSKeyValueObservation?
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
        mediaType: .video,
        position: .unspecified
    )

    override init() {
        super.init()

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        discoveryObservation = discovery.observe(\.devices, options: [.initial]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginSession()
                    } else {
                        self?.authorizationDenied = true
                    }
                }
            }
        default:
            authorizationDenied = true
        }
    }

    func stop() {
        captureQueue.async { [session] in
            session.stopRunning()
        }
    }

    private func beginSession() {
        refreshDevices()
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first?.id
        } else {
            reconfigureSession()
        }
    }

    private func refreshDevices() {
        // Exclude our own virtual camera to avoid a feedback loop.
        devices = discovery.devices
            .filter { $0.uniqueID != VirtualCamera.deviceUID.uuidString }
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }

        if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
            selectedDeviceID = devices.first?.id
        }
    }

    private func reconfigureSession() {
        guard let deviceID = selectedDeviceID,
              let device = AVCaptureDevice(uniqueID: deviceID)
        else { return }

        captureQueue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if !session.outputs.contains(videoOutput) {
                session.addOutput(videoOutput)
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
                try device.lockForConfiguration()
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                device.unlockForConfiguration()
            } catch {
                NSLog("Failed to configure capture input: \(error)")
            }
            session.commitConfiguration()
            if !session.isRunning {
                session.startRunning()
            }
        }
    }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameHandler?(pixelBuffer, timestamp)
    }
}
