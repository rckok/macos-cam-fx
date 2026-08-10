import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager

    var body: some View {
        List(selection: $state.selectedEffectID) {
            Section("Source") {
                Picker("Camera", selection: Binding(
                    get: { capture.selectedDeviceID },
                    set: { capture.selectedDeviceID = $0 }
                )) {
                    ForEach(capture.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .labelsHidden()
            }

            Section("Effects") {
                ForEach(store.effects) { effect in
                    EffectRow(effect: effect)
                        .tag(effect.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                state.removeEffect(effect)
                            }
                        }
                }
                .onMove { source, destination in
                    state.moveEffects(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    state.addEffect()
                } label: {
                    Label("Add Effect", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
        .alert(
            "Camera access denied",
            isPresented: .constant(capture.authorizationDenied)
        ) {
            Button("OK") {}
        } message: {
            Text("Enable camera access for Camera Effects in System Settings → Privacy & Security → Camera.")
        }
    }
}

struct EffectRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var effect: Effect

    var body: some View {
        HStack {
            Toggle("", isOn: $effect.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .onChange(of: effect.enabled) {
                    state.effectToggled(effect)
                }
            Text(effect.name)
                .lineLimit(1)
            Spacer()
            if !effect.diagnostics.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Shader has compile errors")
            }
        }
    }
}
