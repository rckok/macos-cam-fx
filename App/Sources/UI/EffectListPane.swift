import SwiftUI

/// The effect menu, unfolded onto glass while the editor panel is open: the
/// same two groups of effects the system menu lists, with the active one
/// ticked, but with the room a menu does not have for managing them —
/// custom effects can be dragged into a new order, removed, and added.
struct EffectListPane: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    /// Deleting an effect with stages needs a sheet, which the caller owns:
    /// presented from inside the glass it would inherit the dark appearance
    /// the floating controls are pinned to.
    let onDelete: (Effect) -> Void

    /// Reordering is a plain drag gesture on the row's handle, not a
    /// pasteboard drag: the row follows the pointer and the others step
    /// aside, and nothing has to make it across the drop machinery over the
    /// camera view. Rows have one fixed height so the pointer's travel maps
    /// straight onto a position in the list.
    @State private var draggedEffectID: String?
    @State private var dragTranslation: CGFloat = 0

    private let rowHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Built-in")
            ForEach(store.builtInEffects) { effect in
                row(for: effect, at: nil)
            }

            sectionHeader("Custom")
                .padding(.top, 10)
            ForEach(Array(store.effects.enumerated()), id: \.element.id) { index, effect in
                row(for: effect, at: index)
                    .offset(y: rowOffset(at: index, id: effect.id))
                    .zIndex(draggedEffectID == effect.id ? 1 : 0)
            }

            Button {
                state.addEffect()
            } label: {
                Label("Add Effect", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        // Keyed to the landing slot, so the rows stepping aside animate while
        // the dragged row tracks the pointer without lag in between.
        .animation(.snappy(duration: 0.2), value: dropIndex)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
    }

    /// `index` is the effect's place among the custom effects; nil for a
    /// built-in one, which cannot be dragged.
    private func row(for effect: Effect, at index: Int?) -> some View {
        EffectPaneRow(
            effect: effect,
            isActive: state.activeEffectID == effect.id,
            isDragging: draggedEffectID == effect.id,
            height: rowHeight,
            onSelect: { state.select(.effect(effect.id)) },
            onDuplicate: { state.duplicateEffect(effect) },
            onDelete: { onDelete(effect) },
            reorder: index.map { index in
                EffectPaneRow.Reorder(
                    changed: { translation in
                        draggedEffectID = effect.id
                        dragTranslation = translation
                    },
                    ended: { finishDrag(from: index) }
                )
            }
        )
    }

    // MARK: Reordering

    private var draggedIndex: Int? {
        guard let draggedEffectID else { return nil }
        return store.effects.firstIndex { $0.id == draggedEffectID }
    }

    /// Where the dragged row would land if released now.
    private var dropIndex: Int? {
        guard let draggedIndex else { return nil }
        let steps = Int((dragTranslation / (rowHeight + 2)).rounded())
        return (draggedIndex + steps).clamped(to: 0...(store.effects.count - 1))
    }

    /// The dragged row rides with the pointer; rows between its old and new
    /// places shift one slot to open a gap where it will land.
    private func rowOffset(at index: Int, id: String) -> CGFloat {
        guard let draggedIndex, let dropIndex else { return 0 }
        if id == draggedEffectID {
            return dragTranslation
        }
        let slot = rowHeight + 2
        if draggedIndex < index, index <= dropIndex {
            return -slot
        }
        if dropIndex <= index, index < draggedIndex {
            return slot
        }
        return 0
    }

    private func finishDrag(from sourceIndex: Int) {
        defer {
            draggedEffectID = nil
            dragTranslation = 0
        }
        guard let movedID = draggedEffectID, let targetIndex = dropIndex, targetIndex != sourceIndex else { return }
        let effects = store.effects
        // Landing at `targetIndex` means going in front of whatever follows
        // that slot once the row has left its own — or last.
        let anchorID: String? = targetIndex < sourceIndex
            ? effects[targetIndex].id
            : (targetIndex + 1 < effects.count ? effects[targetIndex + 1].id : nil)
        // The reorder and the reset land in one update: every row's new slot
        // is where the drag already had it, give or take the last few points,
        // which the animation settles.
        state.moveEffect(movedID, before: anchorID)
    }
}

/// One effect, laid out like a menu item: a tick column, then the name. Custom
/// effects add a drag handle and a remove button at the trailing edge, so the
/// leading edge lines up across both groups.
private struct EffectPaneRow: View {
    let effect: Effect
    let isActive: Bool
    let isDragging: Bool
    let height: CGFloat
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    /// Present on custom effects only, which are the ones that can move.
    let reorder: Reorder?

    struct Reorder {
        /// The pointer's vertical travel since the drag began.
        let changed: (CGFloat) -> Void
        let ended: () -> Void
    }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .opacity(isActive ? 1 : 0)
                    Text(effect.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let reorder {
                // Only the handle starts a drag, so the row's button keeps
                // its click and the handle keeps the mouse-down. Global
                // coordinates, because the handle moves with the row.
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { reorder.changed($0.translation.height) }
                            .onEnded { _ in reorder.ended() }
                    )
                    .help("Drag to reorder")

                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete effect")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(
            Color.primary.opacity(isHovered || isDragging ? 0.1 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .shadow(color: .black.opacity(isDragging ? 0.3 : 0), radius: 6, y: 2)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(effect.isBuiltIn ? "Duplicate to Custom" : "Duplicate", action: onDuplicate)
            if !effect.isBuiltIn {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

/// Asks what to do with a deleted effect's stages: delete them, or move them
/// to another custom effect.
struct DeleteEffectSheet: View {
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
