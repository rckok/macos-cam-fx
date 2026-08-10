import Foundation
import SystemExtensions

/// Installs and uninstalls the camera system extension via OSSystemExtensionRequest.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {

    enum Status: Equatable {
        case unknown
        case requesting
        case needsUserApproval
        case installed
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "Extension status unknown"
            case .requesting: return "Requesting…"
            case .needsUserApproval: return "Approve in System Settings → Login Items & Extensions"
            case .installed: return "Extension installed"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .unknown

    static var extensionBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.ralphkok.CameraEffects") + ".Extension"
    }

    func install() {
        status = .requesting
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        status = .requesting
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = .needsUserApproval }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed: self.status = .installed
            case .willCompleteAfterReboot: self.status = .failed("Restart required to complete installation")
            @unknown default: self.status = .unknown
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.status = .failed(error.localizedDescription) }
    }
}
