import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showSettings = false
    @State private var showInspector = true

    private let sidebarWidth: CGFloat = 240
    private let inspectorWidth: CGFloat = 260

    var body: some View {
        HSplitView {
            SidebarView(store: state.store, capture: state.capture)
                .frame(minWidth: 180, idealWidth: sidebarWidth, maxWidth: 320)
                .layoutPriority(0)

            VSplitView {
                PreviewView(engine: state.engine)
                    .frame(minWidth: 200, minHeight: 160)
                    .layoutPriority(1)

                if let effect = state.selectedEffect {
                    EditorView(effect: effect)
                        .frame(minWidth: 200, minHeight: 140)
                } else {
                    ContentUnavailableView(
                        "No Effect Selected",
                        systemImage: "wand.and.stars",
                        description: Text("Select an effect in the sidebar or add a new one.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 140)
                }
            }
            .frame(minWidth: 200)
            .layoutPriority(1)

            if showInspector {
                Group {
                    if let effect = state.selectedEffect {
                        InspectorView(effect: effect)
                    } else {
                        Text("No effect selected")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 180, idealWidth: inspectorWidth, maxWidth: 360)
                .layoutPriority(0)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                VirtualCameraToolbar(extensionManager: state.extensionManager, sink: state.sink)
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
                    Label("Parameters", systemImage: "slider.horizontal.3")
                }
            }
        }
    }
}

/// Toolbar cluster for extension install status and the virtual camera toggle.
struct VirtualCameraToolbar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var extensionManager: ExtensionManager
    @ObservedObject var sink: VirtualCameraSink

    var body: some View {
        HStack(spacing: 12) {
            switch extensionManager.status {
            case .installed:
                EmptyView()
            case .unknown:
                Button("Install Extension") {
                    extensionManager.install()
                }
            default:
                Text(extensionManager.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
                Button("Retry") {
                    extensionManager.install()
                }
            }

            Toggle(isOn: $state.virtualCameraEnabled) {
                Label(
                    "Virtual Camera",
                    systemImage: sink.isConnected && state.virtualCameraEnabled
                        ? "video.fill" : "video"
                )
            }
            .toggleStyle(.button)
            .help(virtualCameraHelp)

            if state.virtualCameraEnabled, let error = sink.lastError, !sink.isConnected {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 280)
            }
        }
    }

    private var virtualCameraHelp: String {
        if !state.virtualCameraEnabled {
            return "Start streaming to the virtual camera"
        }
        if sink.isConnected {
            return "Streaming to the virtual camera"
        }
        if let error = sink.lastError {
            return error
        }
        return "Waiting for the camera extension — is it installed?"
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
                Text("Number of past frames available to effects as the 3D texture `uFrames`. Higher values use more GPU memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(8)
    }
}
