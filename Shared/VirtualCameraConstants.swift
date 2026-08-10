import Foundation

/// Identifiers shared between the main app and the camera extension.
/// The app uses the device/stream UIDs to locate the virtual camera's sink
/// stream through the CoreMediaIO C API.
enum VirtualCamera {
    static let deviceName = "Camera Effects"

    static let deviceUID = UUID(uuidString: "A6C1E1A4-63A2-4A31-9F3F-2D6E4B1C9A01")!
    static let sourceStreamUID = UUID(uuidString: "B7D2F2B5-74B3-4B42-8E4E-3E7F5C2D0B02")!
    static let sinkStreamUID = UUID(uuidString: "C8E3A3C6-85C4-4C53-9D5D-4F8A6D3E1C03")!

    /// Fixed output dimensions of the virtual camera.
    static let width = 1280
    static let height = 720
    static let frameRate = 30
}
