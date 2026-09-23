import SwiftUI

/// The camera, with the controls floating over it as clear glass and the
/// panes that unfold from them drawn like system menus: camera and effect
/// pickers, the effect's controls, the background gallery, and — while
/// editing — the effect list. This is the whole window in Basic Mode and
/// the top of it in Editor Mode.
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
    /// Panes hug their content up to this height, then scroll.
    private let paneMaxHeight: CGFloat = 440
    /// The corner radius of a system menu window.
    private let paneShape = RoundedRectangle(cornerRadius: 12)
    /// Clear glass leaves legibility to the caller. The bar's symbols and its
    /// one label need only a hint of a scrim.
    private let controlDim = 0.12
    /// How a system menu comes in: a short fade, already at full size. The
    /// spring this used to be (and the glass materialize under it) is what
    /// made a pane scale up and sit invisible for a beat first.
    private let paneFade = Animation.easeOut(duration: 0.15)

    var body: some View {
        PreviewView(engine: state.engine, contentMode: state.previewFillsWindow ? .fill : .fit)
            .ignoresSafeArea()
            // A click on the camera puts whichever pane is open away. This
            // layer sits under the bar and the pane, so clicks on those
            // still land where they should.
            .overlay {
                if openPane != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { openPane = nil }
                }
            }
            .overlay(alignment: .bottom) {
                // Each pane unfolds towards its own button: the background
                // gallery and the effect list from the left half of the bar,
                // the controls from the right.
                VStack(alignment: openPane == .controls ? .trailing : .leading, spacing: 12) {
                    switch openPane {
                    case .background:
                        backgroundPane
                            .transition(.opacity)
                    case .effects:
                        effectsPane
                            .transition(.opacity)
                    case .controls:
                        controlsPane
                            .transition(.opacity)
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
                        // Clear glass over the feed is dark. The status text
                        // has to follow that, not the OS appearance.
                        .environment(\.colorScheme, .dark)
                        .padding(20)
                }
            }
            .animation(paneFade, value: openPane)
            // The unfolded effect list belongs to editing; the system menu
            // takes over again when the editor closes.
            .onChange(of: state.viewMode) { _, mode in
                if mode == .basic, openPane == .effects {
                    openPane = nil
                }
            }
            // Attached on the window, so the sheet keeps the OS appearance
            // rather than the dark scheme pinned to the clear-glass controls.
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
        // Clear glass over the feed is dark, so the bar is pinned dark.
        // The menus it opens are system menus and keep the OS appearance;
        // the panes that unfold from it do too, and stay outside this scheme.
        .environment(\.colorScheme, .dark)
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
        BackgroundGalleryPane(library: state.backgrounds, onClose: { openPane = nil })
            .paneFrame(width: paneWidth, maxHeight: paneMaxHeight)
            .menuSurface(in: paneShape)
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
        .paneFrame(width: paneWidth, maxHeight: paneMaxHeight)
        .menuSurface(in: paneShape)
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
        .paneFrame(width: paneWidth, maxHeight: paneMaxHeight)
        .menuSurface(in: paneShape)
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

/// A frame that hugs its content up to a height, where `.frame(maxHeight:)`
/// would fill up to it: that modifier takes the parent's proposal whenever
/// the proposal is larger than the child, and the overlay the panes live in
/// proposes the whole window. This one proposes at most `maxHeight` to the
/// child — so the `ViewThatFits` inside knows when to fall back to scrolling
/// — and reports the child's own size.
private struct PaneFrame: Layout {
    let width: CGFloat
    let maxHeight: CGFloat

    private func childProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: width, height: min(proposal.height ?? maxHeight, maxHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return CGSize(width: width, height: 0) }
        let size = child.sizeThatFits(childProposal(proposal))
        return CGSize(width: width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: childProposal(proposal))
    }
}

private extension View {
    /// Fixed width, and a height that follows the content up to `maxHeight`.
    func paneFrame(width: CGFloat, maxHeight: CGFloat) -> some View {
        PaneFrame(width: width, maxHeight: maxHeight) {
            self
        }
    }

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
