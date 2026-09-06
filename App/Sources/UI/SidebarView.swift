import SwiftUI

/// Effect list. Basic Mode shows only the effects; Editor Mode adds their
/// stages plus the controls to create, reorder and delete both.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager

    var body: some View {
        Group {
            if state.viewMode == .basic {
                BasicSidebar(store: store, capture: capture)
            } else {
                EditorSidebar(store: store, capture: capture)
            }
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

private struct CameraSourceSection: View {
    @ObservedObject var capture: CaptureManager

    var body: some View {
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
    }
}

// MARK: - Basic Mode

private struct BasicSidebar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager

    /// Selecting a row is what activates an effect, so the list selection is
    /// the active effect.
    private var activeEffectSelection: Binding<String?> {
        Binding(
            get: { state.activeEffectID },
            set: { newValue in state.select(newValue.map { EffectSelection.effect($0) }) }
        )
    }

    var body: some View {
        List(selection: activeEffectSelection) {
            CameraSourceSection(capture: capture)

            Section("Effects") {
                if store.effects.isEmpty {
                    Text("No effects yet. Switch to Editor Mode to build one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.effects) { effect in
                        BasicEffectRow(
                            effect: effect,
                            isActive: state.activeEffectID == effect.id
                        )
                        .tag(effect.id)
                    }
                }
            }
        }
    }
}

private struct BasicEffectRow: View {
    let effect: Effect
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(effect.name)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor Mode

/// A spot a dragged stage can land in, identified by the row that offers it.
private enum StageDropTarget: Equatable {
    case start(effectID: String)
    case before(effectID: String, stageID: String)
    case end(effectID: String)
}

/// Turns a row into a landing spot for a dragged stage, with an insertion line
/// along the edge the stage would be inserted at.
private struct StageDropZone: ViewModifier {
    let target: StageDropTarget
    var edge: VerticalAlignment = .top
    @Binding var current: StageDropTarget?
    let perform: (String, StageDropTarget) -> Bool

    func body(content: Content) -> some View {
        content
            .dropDestination(for: String.self) { stageIDs, _ in
                current = nil
                guard let stageID = stageIDs.first else { return false }
                return perform(stageID, target)
            } isTargeted: { isTargeted in
                if isTargeted {
                    current = target
                } else if current == target {
                    current = nil
                }
            }
            .overlay(alignment: Alignment(horizontal: .center, vertical: edge)) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .opacity(current == target ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
    func stageDropZone(
        _ target: StageDropTarget,
        edge: VerticalAlignment = .top,
        current: Binding<StageDropTarget?>,
        perform: @escaping (String, StageDropTarget) -> Bool
    ) -> some View {
        modifier(StageDropZone(target: target, edge: edge, current: current, perform: perform))
    }
}

private struct EditorSidebar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager

    @State private var effectToDelete: Effect?
    @State private var collapsedEffectIDs: Set<String> = []
    @State private var editingEffectID: String?
    @State private var editingEffectName = ""
    @State private var dropTarget: StageDropTarget?
    @FocusState private var focusedEffectID: String?

    private let stageIndent: CGFloat = 20

    /// Stage rows are selected through the list itself. A tap gesture of their
    /// own would beat `draggable` to the mouse-down and stop drags starting.
    private var selection: Binding<EffectSelection?> {
        Binding(
            get: { state.selection },
            set: { newValue in
                // Effects are selected on a section header, which the list
                // does not consider one of its rows: it answers the same click
                // by clearing its selection. Keep the effect instead.
                guard let newValue else { return }
                state.select(newValue)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            CameraSourceSection(capture: capture)

            ForEach(store.effects) { effect in
                Section {
                    if !isCollapsed(effect) {
                        ForEach(store.stages(in: effect)) { stage in
                            StageRow(
                                stage: stage,
                                onDuplicate: { state.duplicateStage(stage) },
                                onDelete: { state.removeStage(stage) }
                            )
                            .tag(EffectSelection.stage(stage.id))
                            .padding(.leading, stageIndent)
                            .draggable(stage.id)
                            .stageDropZone(
                                .before(effectID: effect.id, stageID: stage.id),
                                current: $dropTarget,
                                perform: moveStage
                            )
                        }

                        Button {
                            state.addStage(toEffect: effect.id)
                        } label: {
                            Label("Add Stage", systemImage: "plus")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.leading, stageIndent)
                        .stageDropZone(
                            .end(effectID: effect.id),
                            current: $dropTarget,
                            perform: moveStage
                        )
                    }
                } header: {
                    EffectHeaderRow(
                        effect: effect,
                        isExpanded: !isCollapsed(effect),
                        isSelected: state.selection == .effect(effect.id),
                        isActive: state.activeEffectID == effect.id,
                        isEditing: editingEffectID == effect.id,
                        editingName: $editingEffectName,
                        onToggleExpanded: { toggleCollapsed(effect.id) },
                        onSelect: { state.select(.effect(effect.id)) },
                        onStartEditing: { startEditing(effect) },
                        onCommitEditing: { commitEditing(effect) },
                        onCancelEditing: { cancelEditing() },
                        onDelete: { requestDeleteEffect(effect) },
                        focusedEffectID: $focusedEffectID
                    )
                    // A header sits above its stages, so landing on one puts
                    // the stage first — and it is the only target an effect
                    // offers while it is collapsed.
                    .stageDropZone(
                        .start(effectID: effect.id),
                        edge: .bottom,
                        current: $dropTarget,
                        perform: moveStage
                    )
                }
            }
            .onMove { source, destination in
                state.moveEffects(fromOffsets: source, toOffset: destination)
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

    /// Applies a dropped stage. Returns false for payloads that are not one of
    /// our stages, and for the no-op of dropping a stage onto itself.
    private func moveStage(_ stageID: String, to target: StageDropTarget) -> Bool {
        guard store.stage(id: stageID) != nil else { return false }
        switch target {
        case .start(let effectID):
            state.moveStage(stageID, toEffect: effectID, placement: .start)
        case .before(let effectID, let anchorID):
            guard anchorID != stageID else { return false }
            state.moveStage(stageID, toEffect: effectID, placement: .before(anchorID))
        case .end(let effectID):
            state.moveStage(stageID, toEffect: effectID, placement: .end)
        }
        return true
    }

    private func requestDeleteEffect(_ effect: Effect) {
        if effect.stageIDs.isEmpty {
            state.removeEffect(effect, deleteStages: true)
        } else {
            effectToDelete = effect
        }
    }

    private func isCollapsed(_ effect: Effect) -> Bool {
        collapsedEffectIDs.contains(effect.id)
    }

    private func toggleCollapsed(_ effectID: String) {
        if collapsedEffectIDs.contains(effectID) {
            collapsedEffectIDs.remove(effectID)
        } else {
            collapsedEffectIDs.insert(effectID)
        }
    }

    private func startEditing(_ effect: Effect) {
        editingEffectID = effect.id
        editingEffectName = effect.name
        focusedEffectID = effect.id
    }

    private func commitEditing(_ effect: Effect) {
        let trimmed = editingEffectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != effect.name {
            state.renameEffect(effect.id, to: trimmed)
        }
        cancelEditing()
    }

    private func cancelEditing() {
        editingEffectID = nil
        editingEffectName = ""
        focusedEffectID = nil
    }
}

private struct DeleteEffectSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Choice {
        case deleteStages
        case move(toEffectID: String)
    }

    let effect: Effect
    let stageCount: Int
    let destinations: [Effect]
    let onConfirm: (Choice) -> Void

    @State private var deleteStages: Bool
    @State private var targetEffectID: String

    init(effect: Effect, stageCount: Int, destinations: [Effect], onConfirm: @escaping (Choice) -> Void) {
        self.effect = effect
        self.stageCount = stageCount
        self.destinations = destinations
        self.onConfirm = onConfirm
        _deleteStages = State(initialValue: destinations.isEmpty)
        _targetEffectID = State(initialValue: destinations.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \"\(effect.name)\"?")
                .font(.headline)

            Text("This effect has \(stageCount) stage\(stageCount == 1 ? "" : "s").")
                .foregroundStyle(.secondary)

            if destinations.isEmpty {
                Text("There is no other effect to move them to, so deleting this effect deletes its stages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("What should happen to the stages?", selection: $deleteStages) {
                    Text("Move to another effect").tag(false)
                    Text("Delete all stages").tag(true)
                }
                .pickerStyle(.radioGroup)

                if !deleteStages {
                    Picker("Destination effect", selection: $targetEffectID) {
                        ForEach(destinations) { destination in
                            Text(destination.name).tag(destination.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Delete Effect", role: .destructive) {
                    if deleteStages {
                        onConfirm(.deleteStages)
                    } else {
                        onConfirm(.move(toEffectID: targetEffectID))
                    }
                    dismiss()
                }
                .disabled(!deleteStages && targetEffectID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct EffectHeaderRow: View {
    let effect: Effect
    let isExpanded: Bool
    let isSelected: Bool
    let isActive: Bool
    let isEditing: Bool
    @Binding var editingName: String
    let onToggleExpanded: () -> Void
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onCommitEditing: () -> Void
    let onCancelEditing: () -> Void
    let onDelete: () -> Void
    var focusedEffectID: FocusState<String?>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse effect" : "Expand effect")

            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.caption)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .help(isActive ? "Active effect" : "Click to make this the active effect")

            if isEditing {
                TextField("Effect name", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .focused(focusedEffectID, equals: effect.id)
                    .onSubmit(onCommitEditing)
                    .onExitCommand(perform: onCancelEditing)
            } else {
                Text(effect.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .help("Right-click to rename")
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete effect")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Rename", action: onStartEditing)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct StageRow: View {
    @ObservedObject var stage: Stage
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder, or to move this stage to another effect")

            Text(stage.name)
                .lineLimit(1)
                .opacity(stage.isShadowed ? 0.5 : 1)

            Spacer()

            if stage.isShadowed {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help(Stage.shadowedExplanation)
            }

            if !stage.diagnostics.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Shader has compile errors")
            }

            Button(action: onDuplicate) {
                Image(systemName: "plus.square.on.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Duplicate stage")

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove stage")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Duplicate", action: onDuplicate)
            Button("Remove", action: onDelete)
        }
    }
}
