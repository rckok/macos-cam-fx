import SwiftUI

/// The camera, with everything else floating over it as glass: camera and
/// effect pickers, the controls pane that unfolds from its button, and the
/// switch for the editor panel. This is the whole window in Basic Mode and
/// the top of it in Editor Mode; the controls pane shows the effect's
/// controls in the first case and the selected stage's in the second.
struct BasicModeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager
    @ObservedObject var extensionManager: ExtensionManager
    @ObservedObject var sink: VirtualCameraSink

    @State private var showControls = false

    private let controlSize: CGFloat = 40
    /// Clear glass leaves legibility to the caller. The bar's symbols and its
    /// one label need only a hint of a scrim; the controls pane needs more.
    private let controlDim = 0.12

    var body: some View {
        PreviewView(engine: state.engine, contentMode: state.previewFillsWindow ? .fill : .fit)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                VStack(alignment: .trailing, spacing: 12) {
                    if showControls {
                        controlsPane
                            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                    controlBar
                }
                .padding(20)
            }
            .overlay(alignment: .topTrailing) {
                if needsExtensionAttention {
                    VirtualCameraToolbar(extensionManager: extensionManager, sink: sink)
                        .padding(.horizontal, 14)
                        .frame(height: controlSize)
                        .glassSurface(in: Capsule(), dim: 0.2)
                        .padding(20)
                }
            }
            // Glass takes its light or dark tone from the camera feed behind
            // it, not from the system appearance, and over video that is
            // dark. SwiftUI text and symbols on glass follow along through
            // vibrancy, but the pane's sliders, switches, fields and popups
            // are AppKit controls that draw for the window's appearance —
            // black on dark glass in light mode. Pinning the whole HUD to
            // dark keeps every part of it agreeing with the glass.
            .environment(\.colorScheme, .dark)
            .animation(.snappy(duration: 0.3), value: showControls)
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            cameraMenu
            effectMenu
            glassIconButton("slider.horizontal.3", help: showControls ? "Hide controls" : "Effect controls") {
                showControls.toggle()
            }
            .foregroundStyle(showControls ? Color.accentColor : Color.primary)
            glassIconButton(
                "chevron.left.forwardslash.chevron.right",
                help: isEditing ? "Hide the editor" : "Edit this effect"
            ) {
                state.viewMode = isEditing ? .basic : .editor
            }
            .foregroundStyle(isEditing ? Color.accentColor : Color.primary)
        }
    }

    private var isEditing: Bool {
        state.viewMode == .editor
    }

    /// Camera picker plus the two settings that matter while watching the
    /// feed: mirroring, and whether the preview crops to fill the window or
    /// letterboxes to show the whole frame. Frame history stays in Editor
    /// Mode's settings.
    private var cameraMenu: some View {
        Menu {
            if capture.devices.isEmpty {
                Text("No cameras found")
            }
            ForEach(capture.devices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { capture.selectedDeviceID == device.id },
                    set: { _ in capture.selectedDeviceID = device.id }
                ))
            }
            Divider()
            Toggle("Mirror", isOn: $state.flipHorizontal)
            Toggle("Fill Window", isOn: $state.previewFillsWindow)
        } label: {
            Image(systemName: "video")
                .font(.system(size: 15, weight: .medium))
                .frame(width: controlSize, height: controlSize)
                .contentShape(Circle())
        }
        .glassMenu(in: Circle(), dim: controlDim)
        .help("Camera")
    }

    private var effectMenu: some View {
        Menu {
            effectSection("Built-in", store.builtInEffects)
            effectSection("Custom", store.effects)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text(state.activeEffect?.name ?? "Choose Effect")
                    .lineLimit(1)
                    .frame(maxWidth: 200)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: controlSize)
            .contentShape(Capsule())
        }
        .glassMenu(in: Capsule(), dim: controlDim)
        .help("Effect")
    }

    @ViewBuilder
    private func effectSection(_ title: String, _ effects: [Effect]) -> some View {
        if !effects.isEmpty {
            Section(title) {
                ForEach(effects) { effect in
                    Toggle(effect.name, isOn: Binding(
                        get: { state.activeEffectID == effect.id },
                        set: { _ in state.select(.effect(effect.id)) }
                    ))
                }
            }
        }
    }

    private func glassIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: controlSize, height: controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true, dim: controlDim)
        .help(help)
    }

    // MARK: Controls pane

    /// The active effect's `global` controls — or, while a stage is selected
    /// in the editor panel, every control of that stage — on glass.
    private var controlsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(paneTitle)
                    .font(.headline)
                    .lineLimit(1)
                if let stage = state.selectedStage {
                    Text("Stage in \(state.store.effect(containing: stage.id)?.name ?? "effect")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Hugs its content while it fits, and scrolls once it does not.
            ViewThatFits(in: .vertical) {
                paneControls
                ScrollView {
                    paneControls
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 440)
        // Sliders and their labels are fine detail over a moving frame, so
        // this is the one surface that needs a scrim behind it.
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), dim: 0.25)
    }

    private var paneTitle: String {
        state.selectedStage?.name ?? state.activeEffect?.name ?? "Controls"
    }

    /// The selection only points at a stage while the editor panel is open,
    /// so closing the panel brings the effect's controls back on its own.
    @ViewBuilder
    private var paneControls: some View {
        if let stage = state.selectedStage {
            StageControls(stage: stage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        } else if let effect = state.activeEffect {
            EffectControls(effect: effect, store: store)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        } else {
            Text("Choose an effect to see its controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    // MARK: Extension status

    /// Streaming is silent when it works; the status only surfaces when the
    /// extension needs installing, approving, or is still connecting.
    private var needsExtensionAttention: Bool {
        !(extensionManager.status == .installed && sink.isConnected)
    }
}

private extension View {
    /// A `Menu` drawn as one of the floating controls: no system border or
    /// indicator, just its label on glass.
    func glassMenu(in shape: some Shape, dim: Double) -> some View {
        self
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .glassSurface(in: shape, interactive: true, dim: dim)
    }
}
