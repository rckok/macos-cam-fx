import Foundation
import SystemExtensions

/// Installs and uninstalls the camera system extension via OSSystemExtensionRequest.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {

    enum Status: Equatable {
        case checking
        case unknown
        case requesting
        case needsUserApproval
        case installed
        case failed(String)

        var label: String {
            switch self {
            case .checking: return "Checking extension…"
            case .unknown: return "Extension status unknown"
            case .requesting: return "Requesting…"
            case .needsUserApproval: return "Approve in System Settings → Login Items & Extensions"
            case .installed: return "Extension installed"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .checking
    private var propertiesRequest: OSSystemExtensionRequest?

    static var extensionBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "studio.polyglot.CameraEffects") + ".Extension"
    }

    override init() {
        super.init()
        refreshStatus()
    }

    /// Queries whether a matching extension is already enabled, without
    /// triggering an activation prompt.
    func refreshStatus() {
        status = .checking
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        propertiesRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
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
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            if properties.contains(where: \.isEnabled) {
                self.status = .installed
            } else if properties.contains(where: \.isAwaitingUserApproval) {
                self.status = .needsUserApproval
            } else {
                self.status = .unknown
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            if request === self.propertiesRequest {
                self.propertiesRequest = nil
                if self.status == .checking {
                    self.status = .unknown
                }
                return
            }
            switch result {
            case .completed: self.status = .installed
            case .willCompleteAfterReboot: self.status = .failed("Restart required to complete installation")
            @unknown default: self.status = .unknown
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            if request === self.propertiesRequest {
                self.propertiesRequest = nil
                self.status = .unknown
                return
            }
            self.status = .failed(error.localizedDescription)
        }
    }
}
