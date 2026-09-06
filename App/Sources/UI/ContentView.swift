import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showSettings = false
    @State private var showInspector = true
    @State private var showMediaLibrary = false
    @State private var showUniforms = false
    @State private var editorDefaultHeight: CGFloat?

    private let sidebarWidth: CGFloat = 240
    private let inspectorWidth: CGFloat = 260

    var body: some View {
        HSplitView {
            SidebarView(store: state.store, capture: state.capture)
                .frame(minWidth: 180, idealWidth: sidebarWidth, maxWidth: 320)
                .layoutPriority(0)

            centerPane
                .frame(minWidth: 200)
                .layoutPriority(1)

            if showInspector {
                InspectorColumn(store: state.store)
                    .frame(minWidth: 220, idealWidth: inspectorWidth, maxWidth: 400)
                    .layoutPriority(0)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("View Mode", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("Basic Mode plays effects; Editor Mode edits their stages.")

                if state.viewMode == .editor {
                    Button {
                        showUniforms.toggle()
                    } label: {
                        Label("Uniforms", systemImage: "curlybraces")
                    }
                    .help("Built-in shader uniforms")
                    .popover(isPresented: $showUniforms) {
                        ShaderGlobalsView()
                    }

                    Button {
                        showMediaLibrary.toggle()
                    } label: {
                        Label("Media", systemImage: "photo.on.rectangle.angled")
                    }
                    .help("Open the shared media library")
                    .popover(isPresented: $showMediaLibrary) {
                        MediaLibraryView()
                            .environmentObject(state)
                    }
                }

                Button {
                    showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettings) {
                    SettingsPopover()
                }

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "slider.horizontal.3")
                }
                .help("Show or hide the inspector")
            }

            ToolbarItem(placement: .primaryAction) {
                VirtualCameraToolbar(extensionManager: state.extensionManager, sink: state.sink)
            }
        }
    }

    /// Basic Mode is preview-only; Editor Mode splits it with the GLSL editor.
    @ViewBuilder
    private var centerPane: some View {
        if state.viewMode == .basic {
            PreviewView(engine: state.engine)
                .frame(minWidth: 200, minHeight: 160)
        } else {
            GeometryReader { geo in
                let halfHeight = editorDefaultHeight ?? max(geo.size.height * 0.5, 140)
                VSplitView {
                    PreviewView(engine: state.engine)
                        .frame(minWidth: 200, minHeight: 160, idealHeight: halfHeight)

                    if let stage = state.selectedStage {
                        EditorView(stage: stage)
                            .frame(minWidth: 200, minHeight: 140, idealHeight: halfHeight, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "No Stage Selected",
                            systemImage: "wand.and.stars",
                            description: Text("Select a stage in the sidebar, or add one to the active effect.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 140, idealHeight: halfHeight)
                    }
                }
                .onAppear { captureEditorDefaultHeight(geo.size.height) }
                .onChange(of: geo.size.height) { _, height in
                    captureEditorDefaultHeight(height)
                }
            }
        }
    }

    private func captureEditorDefaultHeight(_ totalHeight: CGFloat) {
        guard editorDefaultHeight == nil, totalHeight > 0 else { return }
        editorDefaultHeight = totalHeight * 0.5
    }
}

/// Right-hand column. Observes the store as well as the app state so effect
/// renames and recompiles that reshape the controls land here immediately.
private struct InspectorColumn: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore

    var body: some View {
        InspectorPanel(title: state.activeEffect?.name ?? "Inspector") {
            if state.viewMode == .editor, let stage = state.selectedStage {
                StageInspectorView(stage: stage)
            } else if let effect = state.activeEffect {
                EffectInspectorView(effect: effect, store: store)
            } else {
                Text("Select an effect to adjust its controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }
}

/// Toolbar cluster for extension install status and virtual-camera streaming,
/// which runs automatically whenever the extension is installed.
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
