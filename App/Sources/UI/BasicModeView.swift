import SwiftUI

/// The camera, with everything else floating over it as glass: camera and
/// effect pickers, the effect's controls in a pane that unfolds from its
/// button, and the switch for the editor panel. This is the whole window in
/// Basic Mode and the top of it in Editor Mode.
struct BasicModeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager
    @ObservedObject var extensionManager: ExtensionManager
    @ObservedObject var sink: VirtualCameraSink

    /// The panes that unfold from the control bar. One slot above the bar,
    /// so opening one closes the others.
    private enum Pane {
        case background
        case effects
        case controls
    }

    @State private var openPane: Pane?
    @State private var effectToDelete: Effect?

    private let controlSize: CGFloat = 40
    private let paneWidth: CGFloat = 320
    private let paneShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    /// Clear glass leaves legibility to the caller. The bar's symbols and its
    /// one label need only a hint of a scrim; the panes need more.
    private let controlDim = 0.12
    private let paneDim = 0.25

    var body: some View {
        PreviewView(engine: state.engine, contentMode: state.previewFillsWindow ? .fill : .fit)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                // Each pane unfolds towards its own button: the background
                // gallery and the effect list from the left half of the bar,
                // the controls from the right.
                VStack(alignment: openPane == .controls ? .trailing : .leading, spacing: 12) {
                    switch openPane {
                    case .background:
                        backgroundPane
                            .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
                    case .effects:
                        effectsPane
                            .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
                    case .controls:
                        controlsPane
                            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                    case nil:
                        EmptyView()
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
            .animation(.snappy(duration: 0.3), value: openPane)
            // The unfolded effect list belongs to editing; the system menu
            // takes over again when the editor closes.
            .onChange(of: state.viewMode) { _, mode in
                if mode == .basic, openPane == .effects {
                    openPane = nil
                }
            }
            // Attached outside the dark HUD, so the sheet keeps the window's
            // appearance.
            .sheet(item: $effectToDelete) { effect in
                DeleteEffectSheet(
                    effect: effect,
                    stageCount: effect.stageIDs.count,
                    destinations: store.effects.filter { $0.id != effect.id }
                ) { choice in
                    switch choice {
                    case .deleteStages:
                        state.removeEffect(effect, deleteStages: true)
                    case .move(let targetEffectID):
                        state.removeEffect(effect, deleteStages: false, moveStagesTo: targetEffectID)
                    }
                    effectToDelete = nil
                }
            }
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            cameraMenu
            if isEditing {
                effectListButton
            } else {
                effectMenu
            }
            glassIconButton(
                "slider.horizontal.3",
                help: openPane == .controls ? "Hide controls" : "Effect controls"
            ) {
                toggle(.controls)
            }
            .foregroundStyle(openPane == .controls ? Color.accentColor : Color.primary)
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

    private func toggle(_ pane: Pane) {
        openPane = openPane == pane ? nil : pane
    }

    /// Camera picker plus the settings that matter while watching the feed:
    /// mirroring, whether the preview crops to fill the window or letterboxes
    /// to show the whole frame, and the background image. Frame history stays
    /// in Editor Mode's settings.
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
            Divider()
            // A menu cannot hold a gallery, so this unfolds one; the
            // gallery's None tile is what turns the background off.
            Button("Background…") {
                openPane = .background
            }
        } label: {
            Image(systemName: "video")
                .font(.system(size: 15, weight: .medium))
                .frame(width: controlSize, height: controlSize)
                .contentShape(Circle())
        }
        .glassMenu(in: Circle(), dim: controlDim)
        .help("Camera")
    }

    /// Basic Mode's effect picker: a plain system menu.
    private var effectMenu: some View {
        Menu {
            effectSection("Built-in", store.builtInEffects)
            effectSection("Custom", store.effects)
        } label: {
            effectLabel
        }
        .glassMenu(in: Capsule(), dim: controlDim)
        .help("Effect")
    }

    /// The same control while editing, unfolding the effect list pane instead
    /// of a menu — the list can be managed, a menu can only be picked from.
    private var effectListButton: some View {
        Button {
            toggle(.effects)
        } label: {
            effectLabel
        }
        .buttonStyle(.plain)
        .glassSurface(in: Capsule(), interactive: true, dim: controlDim)
        .foregroundStyle(openPane == .effects ? Color.accentColor : Color.primary)
        .help(openPane == .effects ? "Hide effects" : "Effects")
    }

    private var effectLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
            Text(state.activeEffect?.name ?? "Choose Effect")
                .lineLimit(1)
                .frame(maxWidth: 200)
            Image(systemName: openPane == .effects ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: controlSize)
        .contentShape(Capsule())
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

    // MARK: Panes

    /// The background gallery: pick the image behind the person (or none),
    /// add more, remove some, and choose how carefully the person is cut out.
    private var backgroundPane: some View {
        BackgroundGalleryPane(library: state.backgrounds)
            .frame(width: paneWidth)
            .frame(maxHeight: 440)
            .glassSurface(in: paneShape, dim: paneDim)
    }

    /// The effect menu unfolded, with the management a menu has no room for.
    private var effectsPane: some View {
        let list = EffectListPane(store: store) { effect in
            requestDelete(effect)
        }
        return ViewThatFits(in: .vertical) {
            list
            ScrollView {
                list
            }
        }
        .frame(width: paneWidth)
        .frame(maxHeight: 440)
        .glassSurface(in: paneShape, dim: paneDim)
    }

    /// The active effect's `global` controls on glass. Stage-level controls
    /// are the editor panel's business, so this pane shows the same thing in
    /// both modes.
    private var controlsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.activeEffect?.name ?? "Controls")
                .font(.headline)
                .lineLimit(1)
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
        .frame(width: paneWidth)
        .frame(maxHeight: 440)
        // Sliders and their labels are fine detail over a moving frame, so
        // the panes are the surfaces that need a scrim behind them.
        .glassSurface(in: paneShape, dim: paneDim)
    }

    /// An effect with stages asks what to do with them; an empty one just goes.
    private func requestDelete(_ effect: Effect) {
        if effect.stageIDs.isEmpty {
            state.removeEffect(effect, deleteStages: true)
        } else {
            effectToDelete = effect
        }
    }

    @ViewBuilder
    private var paneControls: some View {
        if let effect = state.activeEffect {
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
