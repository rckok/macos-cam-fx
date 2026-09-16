import SwiftUI

/// The window: the camera with its floating controls, and under it — while
/// Editor Mode is on — the editor panel. Switching modes only slides that
/// panel in and out; nothing above it changes.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    /// Set once the user drags the panel's edge; until then the panel takes
    /// a share of the window.
    @State private var editorPanelHeight: CGFloat?

    /// Enough camera to keep the floating controls usable over it.
    private let minCameraHeight: CGFloat = 220
    private let minEditorPanelHeight: CGFloat = 200
    private let defaultEditorPanelShare: CGFloat = 0.45

    var body: some View {
        // One container for the window, so the glass inside it blends as a
        // whole rather than each piece sampling its neighbours.
        GlassGroup {
            GeometryReader { geo in
                let range = editorPanelHeightRange(in: geo.size.height)
                let panelHeight = (editorPanelHeight ?? geo.size.height * defaultEditorPanelShare)
                    .clamped(to: range)

                VStack(spacing: 0) {
                    BasicModeView(
                        store: state.store,
                        capture: state.capture,
                        extensionManager: state.extensionManager,
                        sink: state.sink
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if state.viewMode == .editor {
                        EditorPanel(store: state.store)
                            .frame(height: panelHeight)
                            // The handle straddles the seam, so half of it is
                            // over the camera. Later in the stack, so it also
                            // draws over the camera's floating controls.
                            .overlay(alignment: .top) {
                                PanelResizeHandle(
                                    height: Binding(
                                        get: { panelHeight },
                                        set: { editorPanelHeight = $0 }
                                    ),
                                    range: range
                                )
                                .offset(y: -4)
                            }
                            .transition(.move(edge: .bottom))
                    }
                }
                // Covers the panel's slide and the camera's stretch to fill
                // the space it leaves, in one motion.
                .animation(.snappy(duration: 0.3), value: state.viewMode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The camera runs to the top edge in both modes, so the window never
        // shows a toolbar; the editor's tools live in the panel's header.
        .toolbar(.hidden, for: .windowToolbar)
        .modifier(CameraAccessAlert(capture: state.capture))
    }

    private func editorPanelHeightRange(in totalHeight: CGFloat) -> ClosedRange<CGFloat> {
        let upper = max(totalHeight - minCameraHeight, minEditorPanelHeight)
        return minEditorPanelHeight...upper
    }
}

/// Observes the capture manager itself, so the window does not redraw for
/// every capture change.
private struct CameraAccessAlert: ViewModifier {
    @ObservedObject var capture: CaptureManager

    func body(content: Content) -> some View {
        content.alert(
            "Camera access denied",
            isPresented: .constant(capture.authorizationDenied)
        ) {
            Button("OK") {}
        } message: {
            Text("Enable camera access for Camera Effects in System Settings → Privacy & Security → Camera.")
        }
    }
}

/// Extension install status and virtual-camera streaming, which runs
/// automatically whenever the extension is installed. Floats over the camera
/// while it needs attention.
struct VirtualCameraToolbar: View {
    @ObservedObject var extensionManager: ExtensionManager
    @ObservedObject var sink: VirtualCameraSink

    var body: some View {
        HStack(spacing: 12) {
            switch extensionManager.status {
            case .installed:
                Label(
                    sink.isConnected ? "Streaming" : "Connecting…",
                    systemImage: sink.isConnected ? "video.fill" : "video"
                )
                .font(.caption)
                .foregroundStyle(sink.isConnected ? Color.green : Color.secondary)
                .help(streamingHelp)
            case .checking:
                Text("Checking extension…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .requesting:
                Text("Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unknown:
                Button("Install Extension") {
                    extensionManager.install()
                }
                .help("Install the virtual camera so other apps can use this feed")
            case .needsUserApproval, .failed:
                Text(extensionManager.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
                Button("Retry") {
                    extensionManager.install()
                }
            }
        }
    }

    private var streamingHelp: String {
        if sink.isConnected {
            return "Streaming to the Camera Effects virtual camera"
        }
        if let error = sink.lastError {
            return error
        }
        return "Connecting to the camera extension…"
    }
}

struct SettingsPopover: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Camera") {
                Toggle("Flip horizontally", isOn: $state.flipHorizontal)
                Text("Mirrors the incoming feed before effects run (like FaceTime).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Frame History") {
                LabeledContent("Frames (N)") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(state.historyDepth) },
                                set: { state.historyDepth = Int($0.rounded()) }
                            ),
                            in: 1...60,
                            step: 1
                        )
                        .frame(width: 160)
                        Text("\(state.historyDepth)")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Text("Number of past frames available to stages as the 3D texture `uFrames`. Higher values use more GPU memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(8)
    }
}
