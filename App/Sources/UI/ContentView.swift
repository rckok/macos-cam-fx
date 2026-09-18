import AppKit
import QuartzCore
import SwiftUI

/// The window: the camera with its floating controls, and under it — while
/// Editor Mode is on — the editor panel. Switching modes slides that panel in
/// and out *by resizing the window*, so the camera above keeps its size.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var window: NSWindow?
    /// Set while the panel slides in or out. The window's frame is the only
    /// thing animated then; the panel's reveal is read off the content height
    /// as the window changes, so the camera above — content minus reveal —
    /// holds still instead of following an animation of its own.
    @State private var slide: PanelSlide?
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
            // The geometry reader is the resize observer: it is laid out again
            // for every frame the window's animation produces.
            GeometryReader { geo in
                let content = geo.size.height
                let panelHeight = slide?.panelHeight ?? panelHeight(in: content)
                let reveal = slide?.reveal(at: content) ?? panelHeight

                VStack(spacing: 0) {
                    BasicModeView(
                        store: state.store,
                        capture: state.capture,
                        extensionManager: state.extensionManager,
                        sink: state.sink
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isPanelMounted {
                        // Its own glass container: glass is drawn by the
                        // container it belongs to, and the window's would
                        // draw the panel's chrome over the camera, outside
                        // the clip below. The panel's glass has nothing to
                        // blend with the floating controls anyway.
                        GlassGroup {
                            EditorPanel(store: state.store)
                        }
                        // Laid out at its full height and clipped to what is
                        // revealed, so it slides in whole instead of squashing
                        // as it grows. Anchored at the bottom, so the bottom
                        // edge comes into view first and the panel appears to
                        // slide down from behind the camera.
                        .frame(height: panelHeight)
                        .frame(height: reveal, alignment: .bottom)
                        .clipped()
                            // The handle straddles the seam, so half of it is
                            // over the camera. Later in the stack, so it also
                            // draws over the camera's floating controls.
                            .overlay(alignment: .top) {
                                PanelResizeHandle(
                                    height: Binding(
                                        get: { panelHeight },
                                        set: { state.editorPanelHeight = $0 }
                                    ),
                                    range: panelHeightRange(in: content)
                                )
                                .offset(y: -4)
                                .allowsHitTesting(slide == nil)
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
            if state.editorPanelHeight == nil {
                state.editorPanelHeight = window.contentLayoutRect.height / 2
            }
            isPanelMounted = true
        }
    }

    /// Grows the window downwards by the panel's height — the first time, by
    /// the camera's own height, doubling the window — with the panel revealed
    /// point for point as the window grows. The screen caps the growth: what
    /// it does not allow comes out of the camera, which then shrinks at the
    /// rate that gets the panel fully in by the time the window stops, and a
    /// window that would run off the bottom is moved up instead, no higher
    /// than the top of the screen.
    private func openPanel() {
        isPanelMounted = true
        guard let window else { return }

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
        let growth = height - frame.height
        frame.size.height = height
        frame.origin.y = top - height
        if let screen {
            frame.origin.y = max(frame.origin.y, screen.minY)
            frame.origin.y = min(frame.origin.y, screen.maxY - height)
        }

        state.editorPanelHeight = target
        // A window that cannot grow at all reveals the panel on its first
        // frame; there is no growth to pace it by.
        let slide = PanelSlide(
            hiddenContentHeight: content,
            revealPerPoint: target / max(growth, 1),
            panelHeight: target
        )
        self.slide = slide
        animate(window, to: frame) {
            finish(slide)
        }
    }

    /// Shrinks the window from the bottom by what the panel shows, with the
    /// panel going out at the rate the window shrinks. The window keeps
    /// whatever position opening gave it.
    private func closePanel() {
        guard let window, isPanelMounted else {
            slide = nil
            isPanelMounted = false
            state.editorDidClose()
            return
        }

        let content = window.contentLayoutRect.height
        let chrome = window.frame.height - content
        let shown = slide?.reveal(at: content) ?? panelHeight(in: content)

        var frame = window.frame
        let top = frame.maxY
        let height = max(frame.height - shown, window.minSize.height)
        frame.size.height = height
        frame.origin.y = top - height

        // Hidden once the window is down to its final height; the min size
        // may hold that above content − shown, in which case the panel goes
        // out a little faster than the window shrinks.
        let finalContent = height - chrome
        let slide = PanelSlide(
            hiddenContentHeight: finalContent,
            revealPerPoint: shown / max(content - finalContent, 1),
            panelHeight: shown
        )
        self.slide = slide
        animate(window, to: frame) {
            finish(slide)
        }
    }

    /// Ends a slide, unless another one has replaced it in the meantime — the
    /// interrupted animation's completion still fires. The stage stays
    /// selected until here, so the editor keeps its contents while it goes.
    private func finish(_ slide: PanelSlide) {
        guard self.slide?.id == slide.id else { return }
        self.slide = nil
        if state.viewMode == .basic {
            isPanelMounted = false
            state.editorDidClose()
        }
    }

    private func animate(_ window: NSWindow, to frame: NSRect, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = slideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }
}

/// Maps the window's content height onto how much of the panel shows while
/// it slides. Everything about the motion — timing, curve, interruptions —
/// is then the window animation's, and the camera is whatever is left.
private struct PanelSlide {
    let id = UUID()
    /// The content height at which none of the panel shows.
    let hiddenContentHeight: CGFloat
    /// Points of panel per point of content: 1 when the window grows by the
    /// whole panel, more when the screen or the minimum size held it back.
    let revealPerPoint: CGFloat
    let panelHeight: CGFloat

    func reveal(at contentHeight: CGFloat) -> CGFloat {
        ((contentHeight - hiddenContentHeight) * revealPerPoint).clamped(to: 0...panelHeight)
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
