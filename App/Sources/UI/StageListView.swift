import SwiftUI

/// The editor panel's left column: the active effect's stages in render
/// order, with the controls to add, reorder, duplicate and remove them. The
/// effect itself is chosen with the floating effect menu; its own actions
/// (rename, duplicate, delete, reorder) sit behind the menu in the header.
struct StageListView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    let effect: Effect

    @State private var effectToDelete: Effect?
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var stages: [Stage] {
        store.stages(in: effect)
    }

    /// Only stage rows are selectable here. Selecting one activates its
    /// effect too, which is a no-op since the list shows the active effect.
    private var selectedStageID: Binding<String?> {
        Binding(
            get: { state.selectedStage?.id },
            set: { newValue in
                // Clicking past the last row should not deselect the effect.
                guard let newValue else { return }
                state.select(.stage(newValue))
            }
        )
    }

    var body: some View {
        List(selection: selectedStageID) {
            if stages.isEmpty {
                Text(effect.isBuiltIn
                     ? "This effect has no stages."
                     : "No stages yet. Add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                StageRow(
                    stage: stage,
                    index: index,
                    isReadOnly: effect.isBuiltIn,
                    onDuplicate: { state.duplicateStage(stage) },
                    onDelete: { state.removeStage(stage) }
                )
                .tag(stage.id)
                .contextMenu {
                    if !effect.isBuiltIn {
                        stageActions(for: stage)
                    }
                }
            }
            .onMove(perform: moveHandler)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
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
        .onChange(of: effect.id) { _, _ in
            cancelRename()
        }
    }

    // MARK: Header

    /// The effect's name and the menu of actions on the effect.
    private var header: some View {
        HStack(spacing: 8) {
            if isRenaming {
                TextField("Effect name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($nameFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
            } else {
                Text(effect.name)
                    .font(.headline)
                    .lineLimit(1)
                if effect.isBuiltIn {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Built-in effect: read-only")
                }
            }

            Spacer()

            Menu {
                effectActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Effect actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .glassChrome()
    }

    @ViewBuilder
    private var effectActions: some View {
        if effect.isBuiltIn {
            Button("Duplicate to Custom") { state.duplicateEffect(effect) }
        } else {
            Button("Rename") { startRename() }
            Button("Duplicate") { state.duplicateEffect(effect) }
            Button("Move Up") { moveEffect(by: -1) }
                .disabled(!canMoveEffect(by: -1))
            Button("Move Down") { moveEffect(by: 1) }
                .disabled(!canMoveEffect(by: 1))
            Button("Delete Effect", role: .destructive) { requestDelete() }
        }
        Divider()
        Button("New Effect") { state.addEffect() }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if effect.isBuiltIn {
                Text("Built-in stages are read-only. Duplicate the effect to edit a copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Duplicate") { state.duplicateEffect(effect) }
                    .glassChromeButton()
                    .help("Copy this effect and its stages into Custom effects, where they can be edited")
            } else {
                Button {
                    state.addStage(toEffect: effect.id)
                } label: {
                    Label("Add Stage", systemImage: "plus")
                }
                .glassChromeButton()
                Spacer()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .glassChrome()
    }

    // MARK: Stage actions

    @ViewBuilder
    private func stageActions(for stage: Stage) -> some View {
        Button("Duplicate") { state.duplicateStage(stage) }
        Button("Remove") { state.removeStage(stage) }

        // Only one effect is listed at a time, so this replaces dragging a
        // stage across to another effect.
        let destinations = store.effects.filter { $0.id != effect.id }
        if !destinations.isEmpty {
            Menu("Move to") {
                ForEach(destinations) { destination in
                    Button(destination.name) {
                        state.moveStage(stage.id, toEffect: destination.id, placement: .end)
                    }
                }
            }
        }
    }

    /// Built-in stages stay where the bundle puts them.
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        effect.isBuiltIn ? nil : moveStages
    }

    /// `onMove` hands over indices into the list as it was before the drag:
    /// the item goes in front of whatever sat at `destination`, or last.
    private func moveStages(from source: IndexSet, to destination: Int) {
        let ids = effect.stageIDs
        guard let sourceIndex = source.first, ids.indices.contains(sourceIndex) else { return }
        // Dropping back where it came from.
        if destination == sourceIndex || destination == sourceIndex + 1 { return }
        let placement: StagePlacement = destination < ids.count ? .before(ids[destination]) : .end
        state.moveStage(ids[sourceIndex], toEffect: effect.id, placement: placement)
    }

    // MARK: Effect actions

    private func canMoveEffect(by offset: Int) -> Bool {
        guard let index = store.effects.firstIndex(where: { $0.id == effect.id }) else { return false }
        return store.effects.indices.contains(index + offset)
    }

    /// Effect order is what the effect menu lists; every effect is its own
    /// pipeline, so this never touches the render chain.
    private func moveEffect(by offset: Int) {
        let effects = store.effects
        guard let index = effects.firstIndex(where: { $0.id == effect.id }),
              effects.indices.contains(index + offset)
        else { return }
        // Moving down means landing after the next effect, i.e. before the one
        // past it — or last when there is none.
        let anchorIndex = offset < 0 ? index + offset : index + offset + 1
        let anchorID = effects.indices.contains(anchorIndex) ? effects[anchorIndex].id : nil
        state.moveEffect(effect.id, before: anchorID)
    }

    private func requestDelete() {
        if effect.stageIDs.isEmpty {
            state.removeEffect(effect, deleteStages: true)
        } else {
            effectToDelete = effect
        }
    }

    private func startRename() {
        draftName = effect.name
        isRenaming = true
        nameFieldFocused = true
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != effect.name {
            state.renameEffect(effect.id, to: trimmed)
        }
        cancelRename()
    }

    private func cancelRename() {
        isRenaming = false
        draftName = ""
        nameFieldFocused = false
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
                .help(isReadOnly ? "Built-in stage: read-only" : "Drag to reorder")

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
