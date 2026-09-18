import AppKit
import QuartzCore
import SwiftUI

/// The window: the camera with its floating controls, and under it — while
/// Editor Mode is on — the editor panel. Switching modes slides that panel in
/// and out *by resizing the window*, so the camera above keeps its size.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var window: NSWindow?
    /// How much of the editor panel shows, in points. Opening and closing
    /// animate it in step with the window's frame — the window grows by the
    /// same amount the panel reveals, so the camera stays put — and the seam
    /// drag sets it directly.
    @State private var panelReveal: CGFloat = 0
    /// The panel stays in the hierarchy while it slides out.
    @State private var isPanelMounted = false

    /// Enough camera to keep the floating controls usable over it.
    private let minCameraHeight: CGFloat = 220
    private let minEditorPanelHeight: CGFloat = 200
    private let slideDuration: TimeInterval = 0.3

    var body: some View {
        // One container for the window, so the glass inside it blends as a
        // whole rather than each piece sampling its neighbours.
        GlassGroup {
            GeometryReader { geo in
                let panelHeight = panelHeight(in: geo.size.height)

                VStack(spacing: 0) {
                    BasicModeView(
                        store: state.store,
                        capture: state.capture,
                        extensionManager: state.extensionManager,
                        sink: state.sink
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isPanelMounted {
                        EditorPanel(store: state.store)
                            // Laid out at its full height and clipped to what
                            // is revealed, so it slides in whole instead of
                            // squashing as it grows.
                            .frame(height: panelHeight)
                            .frame(height: min(panelReveal, panelHeight), alignment: .top)
                            .clipped()
                            // The handle straddles the seam, so half of it is
                            // over the camera. Later in the stack, so it also
                            // draws over the camera's floating controls.
                            .overlay(alignment: .top) {
                                PanelResizeHandle(
                                    height: Binding(
                                        get: { panelHeight },
                                        set: { newHeight in
                                            panelReveal = newHeight
                                            state.editorPanelHeight = newHeight
                                        }
                                    ),
                                    range: panelHeightRange(in: geo.size.height)
                                )
                                .offset(y: -4)
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowAccessor(onWindow: attach))
        .onChange(of: state.viewMode) { _, mode in
            if mode == .editor {
                openPanel()
            } else {
                closePanel()
            }
        }
        // The camera runs to the top edge in both modes, so the window never
        // shows a toolbar; the editor's tools live in the panel's header.
        .toolbar(.hidden, for: .windowToolbar)
        .modifier(CameraAccessAlert(capture: state.capture))
    }

    // MARK: Panel height

    private func panelHeightRange(in totalHeight: CGFloat) -> ClosedRange<CGFloat> {
        let upper = max(totalHeight - minCameraHeight, minEditorPanelHeight)
        return minEditorPanelHeight...upper
    }

    /// The panel's full height: what was remembered, held to what the window
    /// can give it. Resizing the window therefore goes to the camera first,
    /// and to the panel only once the camera is at its minimum.
    private func panelHeight(in totalHeight: CGFloat) -> CGFloat {
        (state.editorPanelHeight ?? totalHeight / 2).clamped(to: panelHeightRange(in: totalHeight))
    }

    // MARK: Window

    private func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // AppKit remembers the frame across launches under this name, and
        // restores it here when it has one.
        window.setFrameAutosaveName("CameraEffects.MainWindow")

        // Launched with the editor open: the remembered frame already has the
        // panel in it, so it shows without any sliding.
        if state.viewMode == .editor {
            let target = state.editorPanelHeight ?? window.contentLayoutRect.height / 2
            state.editorPanelHeight = target
            panelReveal = target
            isPanelMounted = true
        }
    }

    /// Grows the window downwards by the panel's height — the first time, by
    /// the camera's own height, doubling the window — and slides the panel
    /// in at the same rate. The screen caps the growth: what it does not
    /// allow comes out of the camera, and a window that would run off the
    /// bottom is moved up instead, no higher than the top of the screen.
    private func openPanel() {
        isPanelMounted = true
        guard let window else {
            panelReveal = state.editorPanelHeight ?? minEditorPanelHeight
            return
        }

        let content = window.contentLayoutRect.height
        let chrome = window.frame.height - content
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame

        var target = state.editorPanelHeight ?? content
        var frame = window.frame
        let top = frame.maxY
        var height = frame.height + target
        if let screen {
            height = min(height, screen.height)
        }
        target = max(min(target, height - chrome - minCameraHeight), minEditorPanelHeight)
        frame.size.height = height
        frame.origin.y = top - height
        if let screen {
            frame.origin.y = max(frame.origin.y, screen.minY)
            frame.origin.y = min(frame.origin.y, screen.maxY - height)
        }

        state.editorPanelHeight = target
        slide(window, to: frame) {
            panelReveal = target
        }
    }

    /// Shrinks the window from the bottom by what the panel showed, with the
    /// panel sliding out at the same rate. The window keeps whatever position
    /// opening gave it.
    private func closePanel() {
        guard let window, isPanelMounted else {
            panelReveal = 0
            isPanelMounted = false
            return
        }

        var frame = window.frame
        let top = frame.maxY
        let height = max(frame.height - panelReveal, window.minSize.height)
        frame.size.height = height
        frame.origin.y = top - height

        slide(window, to: frame, changes: {
            panelReveal = 0
        }, completion: {
            // Reopened before the slide finished: leave it mounted.
            if state.viewMode == .basic {
                isPanelMounted = false
            }
        })
    }

    /// Runs a window frame change and a SwiftUI state change on one clock:
    /// the same duration and the same cubic Bézier on both sides, so the
    /// panel's reveal tracks the window's growth frame for frame.
    private func slide(
        _ window: NSWindow,
        to frame: NSRect,
        changes: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = slideDuration
            context.timingFunction = SlideCurve.timingFunction
            window.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
        withAnimation(SlideCurve.animation(duration: slideDuration), changes)
    }
}

/// An ease-out, written once for each framework.
private enum SlideCurve {
    private static let controlPoints: (Float, Float, Float, Float) = (0.2, 0.9, 0.3, 1.0)

    static var timingFunction: CAMediaTimingFunction {
        let (c0x, c0y, c1x, c1y) = controlPoints
        return CAMediaTimingFunction(controlPoints: c0x, c0y, c1x, c1y)
    }

    static func animation(duration: TimeInterval) -> Animation {
        let (c0x, c0y, c1x, c1y) = controlPoints
        return .timingCurve(Double(c0x), Double(c0y), Double(c1x), Double(c1y), duration: duration)
    }
}

/// Hands the hosting `NSWindow` to SwiftUI, which has no other way to get at
/// the frame it lives in.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = onWindow
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Off the layout pass, so the callback can touch view state.
            DispatchQueue.main.async { [onWindow] in
                onWindow?(window)
            }
        }
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
