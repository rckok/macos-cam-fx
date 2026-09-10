import SwiftUI
import UniformTypeIdentifiers

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

/// Header of the effects section: switches the list between the effects that
/// ship with the app and the user's own.
private struct EffectsSectionHeader: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack {
            Text("Effects")
            Spacer()
            Picker("Effects", selection: $state.effectsSource) {
                ForEach(EffectsSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 140)
            .help("Built-in effects ship with the app and are read-only; Custom effects are yours to edit.")
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
            set: { newValue in
                // Clicking past the last row should not turn every effect off.
                guard let newValue else { return }
                state.select(.effect(newValue))
            }
        )
    }

    var body: some View {
        List(selection: activeEffectSelection) {
            CameraSourceSection(capture: capture)

            Section {
                let effects = store.effects(in: state.effectsSource)
                if effects.isEmpty {
                    Text(state.effectsSource == .custom
                         ? "No custom effects yet. Switch to Editor Mode to build one, or duplicate a built-in effect."
                         : "This build ships no effects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(effects) { effect in
                        BasicEffectRow(
                            effect: effect,
                            isActive: state.activeEffectID == effect.id
                        )
                        .tag(effect.id)
                    }
                }
            } header: {
                EffectsSectionHeader()
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

// MARK: - Editor Mode drag and drop

private extension UTType {
    static let cameraEffectsStage = UTType(exportedAs: "studio.polyglot.CameraEffects.stage")
    static let cameraEffectsEffect = UTType(exportedAs: "studio.polyglot.CameraEffects.effect")
}

/// Stages and effects carry distinct payload types, so a stage can never land
/// on the target that reorders effects, and neither accepts foreign drags.
private struct DraggedStage: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cameraEffectsStage)
    }
}

private struct DraggedEffect: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cameraEffectsEffect)
    }
}

/// A spot a dragged stage can land in, named after the row that offers it.
private enum StageDropTarget: Equatable {
    case start(effectID: String)
    case before(effectID: String, stageID: String)
    case end(effectID: String)
}

private enum EffectDropTarget: Equatable {
    case before(effectID: String)
    case end
}

/// Turns a row into a landing spot, with an insertion line along the edge the
/// dragged item would be inserted at while the pointer is over it.
private struct DropZone<Payload: Transferable, Target: Equatable>: ViewModifier {
    let target: Target
    var edge: VerticalAlignment = .top
    @Binding var current: Target?
    let perform: (Payload, Target) -> Bool

    func body(content: Content) -> some View {
        content
            .dropDestination(for: Payload.self) { payloads, _ in
                current = nil
                guard let payload = payloads.first else { return false }
                return perform(payload, target)
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
        perform: @escaping (DraggedStage, StageDropTarget) -> Bool
    ) -> some View {
        modifier(DropZone<DraggedStage, StageDropTarget>(
            target: target, edge: edge, current: current, perform: perform
        ))
    }

    func effectDropZone(
        _ target: EffectDropTarget,
        current: Binding<EffectDropTarget?>,
        perform: @escaping (DraggedEffect, EffectDropTarget) -> Bool
    ) -> some View {
        modifier(DropZone<DraggedEffect, EffectDropTarget>(
            target: target, edge: .top, current: current, perform: perform
        ))
    }
}

// MARK: - Editor Mode

private struct EditorSidebar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager

    @State private var effectToDelete: Effect?
    @State private var collapsedEffectIDs: Set<String> = []
    @State private var editingEffectID: String?
    @State private var editingEffectName = ""
    @State private var stageDropTarget: StageDropTarget?
    @State private var effectDropTarget: EffectDropTarget?
    @FocusState private var focusedEffectID: String?

    private let stageIndent: CGFloat = 20

    /// Every row is selected through the list itself. A tap gesture of its own
    /// would beat `draggable` to the mouse-down and stop drags from starting,
    /// which is why effects are rows here rather than section headers.
    private var selection: Binding<EffectSelection?> {
        Binding(
            get: { state.selection },
            set: { newValue in
                // Clicking past the last row should not turn every effect off.
                guard let newValue else { return }
                state.select(newValue)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            CameraSourceSection(capture: capture)

            Section {
                if state.effectsSource == .builtIn {
                    ForEach(store.builtInEffects) { effect in
                        builtInRows(for: effect)
                    }
                } else {
                    if store.effects.isEmpty {
                        Text("No custom effects yet. Add one below, or duplicate a built-in effect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.effects) { effect in
                        rows(for: effect)
                    }
                }
            } header: {
                EffectsSectionHeader()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if state.effectsSource == .builtIn {
                    Text("Built-in effects are read-only. Duplicate one to edit a copy in Custom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        state.addEffect()
                    } label: {
                        Label("Add Effect", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()
            }
            .padding(8)
            .background(.bar)
            .effectDropZone(.end, current: $effectDropTarget, perform: moveEffect)
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

    /// One effect: its header, then its stages and their trailing "Add Stage"
    /// row while it is expanded. All of them are list rows, so all of them can
    /// be selected, dragged and dropped onto.
    @ViewBuilder
    private func rows(for effect: Effect) -> some View {
        EffectHeaderRow(
            effect: effect,
            isExpanded: !isCollapsed(effect),
            isActive: state.activeEffectID == effect.id,
            isEditing: editingEffectID == effect.id,
            isReadOnly: false,
            editingName: $editingEffectName,
            onToggleExpanded: { toggleCollapsed(effect.id) },
            onStartEditing: { startEditing(effect) },
            onCommitEditing: { commitEditing(effect) },
            onCancelEditing: { cancelEditing() },
            onDelete: { requestDeleteEffect(effect) },
            onDuplicate: { state.duplicateEffect(effect) },
            focusedEffectID: $focusedEffectID
        )
        .tag(EffectSelection.effect(effect.id))
        .draggable(DraggedEffect(id: effect.id))
        .effectDropZone(.before(effectID: effect.id), current: $effectDropTarget, perform: moveEffect)
        // A header sits above its own stages, so a stage landing on one goes
        // first — and it is the only target an effect offers while collapsed.
        .stageDropZone(
            .start(effectID: effect.id),
            edge: .bottom,
            current: $stageDropTarget,
            perform: moveStage
        )

        if !isCollapsed(effect) {
            ForEach(Array(store.stages(in: effect).enumerated()), id: \.element.id) { index, stage in
                StageRow(
                    stage: stage,
                    index: index,
                    isReadOnly: false,
                    onDuplicate: { state.duplicateStage(stage) },
                    onDelete: { state.removeStage(stage) }
                )
                .tag(EffectSelection.stage(stage.id))
                .padding(.leading, stageIndent)
                .draggable(DraggedStage(id: stage.id))
                .stageDropZone(
                    .before(effectID: effect.id, stageID: stage.id),
                    current: $stageDropTarget,
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
            .stageDropZone(.end(effectID: effect.id), current: $stageDropTarget, perform: moveStage)
        }
    }

    /// A built-in effect: selectable and expandable like a custom one, but with
    /// no drag, rename, delete or stage editing. "Duplicate" is the way in.
    @ViewBuilder
    private func builtInRows(for effect: Effect) -> some View {
        EffectHeaderRow(
            effect: effect,
            isExpanded: !isCollapsed(effect),
            isActive: state.activeEffectID == effect.id,
            isEditing: false,
            isReadOnly: true,
            editingName: $editingEffectName,
            onToggleExpanded: { toggleCollapsed(effect.id) },
            onStartEditing: {},
            onCommitEditing: {},
            onCancelEditing: {},
            onDelete: {},
            onDuplicate: { state.duplicateEffect(effect) },
            focusedEffectID: $focusedEffectID
        )
        .tag(EffectSelection.effect(effect.id))

        if !isCollapsed(effect) {
            ForEach(Array(store.stages(in: effect).enumerated()), id: \.element.id) { index, stage in
                StageRow(
                    stage: stage,
                    index: index,
                    isReadOnly: true,
                    onDuplicate: {},
                    onDelete: {}
                )
                .tag(EffectSelection.stage(stage.id))
                .padding(.leading, stageIndent)
            }
        }
    }

    /// Applies a dropped stage. Returns false for the no-op of dropping a stage
    /// onto itself, and for a stage that has since disappeared.
    private func moveStage(_ dragged: DraggedStage, to target: StageDropTarget) -> Bool {
        guard store.stage(id: dragged.id) != nil else { return false }
        switch target {
        case .start(let effectID):
            state.moveStage(dragged.id, toEffect: effectID, placement: .start)
        case .before(let effectID, let anchorID):
            guard anchorID != dragged.id else { return false }
            state.moveStage(dragged.id, toEffect: effectID, placement: .before(anchorID))
        case .end(let effectID):
            state.moveStage(dragged.id, toEffect: effectID, placement: .end)
        }
        return true
    }

    private func moveEffect(_ dragged: DraggedEffect, to target: EffectDropTarget) -> Bool {
        guard store.effect(id: dragged.id) != nil else { return false }
        switch target {
        case .before(let anchorID):
            guard anchorID != dragged.id else { return false }
            state.moveEffect(dragged.id, before: anchorID)
        case .end:
            state.moveEffect(dragged.id, before: nil)
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
    let isActive: Bool
    let isEditing: Bool
    /// Built-in effects: no rename or delete; duplicating is the only action.
    let isReadOnly: Bool
    @Binding var editingName: String
    let onToggleExpanded: () -> Void
    let onStartEditing: () -> Void
    let onCommitEditing: () -> Void
    let onCancelEditing: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
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
            }

            Spacer()

            if isReadOnly {
                Button(action: onDuplicate) {
                    Image(systemName: "plus.square.on.square")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Duplicate to Custom effects, where the copy can be edited")
            } else {
                if !isEditing {
                    Button(action: onStartEditing) {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename effect")
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete effect")
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if isReadOnly {
                Button("Duplicate to Custom", action: onDuplicate)
            } else {
                Button("Rename", action: onStartEditing)
                Button("Duplicate", action: onDuplicate)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

private struct StageRow: View {
    @ObservedObject var stage: Stage
    /// Position in the effect: the value of `uStageIndex` and the argument
    /// `ceStageTexture(index, uv)` takes to read this stage.
    let index: Int
    /// Built-in stages: no drag handle, duplicate or remove.
    let isReadOnly: Bool
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private var hasErrors: Bool {
        stage.allDiagnostics.contains { $0.severity == .error }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isReadOnly ? "lock" : "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(isReadOnly
                      ? "Built-in stage: read-only"
                      : "Drag to reorder, or to move this stage to another effect")

            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Stage index: read this stage with ceStageTexture(\(index), uv)")

            Text(stage.name)
                .lineLimit(1)
                .opacity(stage.isShadowed ? 0.5 : 1)

            Spacer()

            if stage.isShadowed {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help(Stage.shadowedExplanation)
            }

            if !stage.allDiagnostics.isEmpty {
                Image(systemName: hasErrors ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasErrors ? .red : .yellow)
                    .help(hasErrors ? "Shader has compile errors" : "Shader has warnings")
            }

            if !isReadOnly {
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
        }
        .padding(.vertical, 3)
        .contextMenu {
            if !isReadOnly {
                Button("Duplicate", action: onDuplicate)
                Button("Remove", action: onDelete)
            }
        }
    }
}
