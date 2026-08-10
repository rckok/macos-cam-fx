import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showSettings = false
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(store: state.store, capture: state.capture)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VSplitView {
                PreviewView(engine: state.engine)
                    .frame(minHeight: 220, idealHeight: 340)
                    .layoutPriority(1)
                if let effect = state.selectedEffect {
                    EditorView(effect: effect)
                        .frame(minHeight: 200)
                } else {
                    ContentUnavailableView(
                        "No Effect Selected",
                        systemImage: "wand.and.stars",
                        description: Text("Select an effect in the sidebar or add a new one.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            if let effect = state.selectedEffect {
                InspectorView(effect: effect)
                    .inspectorColumnWidth(min: 240, ideal: 280)
            } else {
                Text("No effect selected")
                    .foregroundStyle(.secondary)
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
            .help(
                state.virtualCameraEnabled
                    ? (sink.isConnected
                        ? "Streaming to the virtual camera"
                        : "Waiting for the camera extension — is it installed?")
                    : "Start streaming to the virtual camera"
            )
        }
    }
}

struct SettingsPopover: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
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
