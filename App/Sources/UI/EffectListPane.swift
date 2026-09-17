import SwiftUI
import UniformTypeIdentifiers

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

    @State private var dropTarget: EffectDropTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Built-in")
            ForEach(store.builtInEffects) { effect in
                row(for: effect)
            }

            sectionHeader("Custom")
                .padding(.top, 10)
            ForEach(store.effects) { effect in
                row(for: effect)
                    .effectDropZone(.before(effectID: effect.id), current: $dropTarget, perform: moveEffect)
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
            .padding(.vertical, 5)
            .effectDropZone(.end, current: $dropTarget, perform: moveEffect)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
    }

    private func row(for effect: Effect) -> some View {
        EffectPaneRow(
            effect: effect,
            isActive: state.activeEffectID == effect.id,
            onSelect: { state.select(.effect(effect.id)) },
            onDuplicate: { state.duplicateEffect(effect) },
            onDelete: { onDelete(effect) }
        )
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
}

/// One effect, laid out like a menu item: a tick column, then the name. Custom
/// effects add a drag handle and a remove button at the trailing edge, so the
/// leading edge lines up across both groups.
private struct EffectPaneRow: View {
    let effect: Effect
    let isActive: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

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

            if !effect.isBuiltIn {
                // Only the handle starts a drag: a drag on the button would
                // fight its press for the mouse-down.
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .draggable(DraggedEffect(id: effect.id)) {
                        Text(effect.name)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
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
        .padding(.vertical, 5)
        .background(
            Color.primary.opacity(isHovered ? 0.1 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
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

// MARK: - Drag and drop

private extension UTType {
    /// Declared in Info.plist, so nothing but an effect can land on the
    /// targets that reorder effects.
    static let cameraEffectsEffect = UTType(exportedAs: "studio.polyglot.CameraEffects.effect")
}

private struct DraggedEffect: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cameraEffectsEffect)
    }
}

/// A spot a dragged effect can land in, named after the row that offers it.
private enum EffectDropTarget: Equatable {
    case before(effectID: String)
    case end
}

/// Turns a row into a landing spot, with an insertion line along its top edge
/// while the pointer is over it.
private struct EffectDropZone: ViewModifier {
    let target: EffectDropTarget
    @Binding var current: EffectDropTarget?
    let perform: (DraggedEffect, EffectDropTarget) -> Bool

    func body(content: Content) -> some View {
        content
            .dropDestination(for: DraggedEffect.self) { payloads, _ in
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
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .opacity(current == target ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
    func effectDropZone(
        _ target: EffectDropTarget,
        current: Binding<EffectDropTarget?>,
        perform: @escaping (DraggedEffect, EffectDropTarget) -> Bool
    ) -> some View {
        modifier(EffectDropZone(target: target, current: current, perform: perform))
    }
}
