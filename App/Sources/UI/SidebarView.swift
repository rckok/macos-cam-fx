import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore
    @ObservedObject var capture: CaptureManager
    @State private var groupToDelete: EffectGroup?
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var editingGroupID: String?
    @State private var editingGroupName = ""
    @FocusState private var focusedGroupID: String?

    private let effectIndent: CGFloat = 20

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

            ForEach(store.groups) { group in
                Section {
                    if !isCollapsed(group) {
                        ForEach(store.effects(in: group)) { effect in
                            EffectRow(effect: effect, onDelete: {
                                state.removeEffect(effect)
                            })
                            .tag(effect.id)
                            .padding(.leading, effectIndent)
                            .draggable(effect.id)
                            .dropDestination(for: String.self) { droppedIDs, _ in
                                guard let droppedID = droppedIDs.first, droppedID != effect.id else { return false }
                                state.moveEffect(droppedID, toGroup: group.id, beforeEffectID: effect.id)
                                return true
                            }
                        }
                        .onMove { source, destination in
                            state.moveEffects(inGroup: group.id, fromOffsets: source, toOffset: destination)
                        }

                        Button {
                            state.addEffect(toGroup: group.id)
                        } label: {
                            Label("Add Effect", systemImage: "plus")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.leading, effectIndent)
                        .dropDestination(for: String.self) { droppedIDs, _ in
                            guard let droppedID = droppedIDs.first else { return false }
                            state.moveEffect(droppedID, toGroup: group.id)
                            return true
                        }
                    }
                } header: {
                    GroupHeaderRow(
                        group: group,
                        isExpanded: !isCollapsed(group),
                        isEditing: editingGroupID == group.id,
                        editingName: $editingGroupName,
                        canDelete: store.groups.count > 1,
                        onToggleExpanded: { toggleCollapsed(group.id) },
                        onToggleEnabled: { enabled in
                            state.setGroupEnabled(group.id, enabled: enabled)
                        },
                        onStartEditing: {
                            startEditing(group)
                        },
                        onCommitEditing: {
                            commitEditing(group)
                        },
                        onCancelEditing: {
                            cancelEditing()
                        },
                        onDelete: {
                            requestDeleteGroup(group)
                        },
                        focusedGroupID: $focusedGroupID
                    )
                    .dropDestination(for: String.self) { droppedIDs, _ in
                        guard let droppedID = droppedIDs.first else { return false }
                        state.moveEffect(droppedID, toGroup: group.id)
                        return true
                    }
                }
            }
            .onMove { source, destination in
                state.moveGroups(fromOffsets: source, toOffset: destination)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    state.addGroup()
                } label: {
                    Label("Add Group", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)

                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
        .sheet(item: $groupToDelete) { group in
            DeleteGroupSheet(
                group: group,
                destinationGroups: store.groups.filter { $0.id != group.id }
            ) { choice in
                switch choice {
                case .deleteEffects:
                    state.removeGroup(group, deleteEffects: true)
                case .move(let targetGroupID):
                    state.removeGroup(group, deleteEffects: false, moveEffectsTo: targetGroupID)
                }
                groupToDelete = nil
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

    private func requestDeleteGroup(_ group: EffectGroup) {
        if group.effectIDs.isEmpty {
            state.removeGroup(group, deleteEffects: true)
        } else {
            groupToDelete = group
        }
    }

    private func isCollapsed(_ group: EffectGroup) -> Bool {
        collapsedGroupIDs.contains(group.id)
    }

    private func toggleCollapsed(_ groupID: String) {
        if collapsedGroupIDs.contains(groupID) {
            collapsedGroupIDs.remove(groupID)
        } else {
            collapsedGroupIDs.insert(groupID)
        }
    }

    private func startEditing(_ group: EffectGroup) {
        editingGroupID = group.id
        editingGroupName = group.name
        focusedGroupID = group.id
    }

    private func commitEditing(_ group: EffectGroup) {
        let trimmed = editingGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != group.name {
            state.renameGroup(group.id, to: trimmed)
        }
        cancelEditing()
    }

    private func cancelEditing() {
        editingGroupID = nil
        editingGroupName = ""
        focusedGroupID = nil
    }
}

private struct DeleteGroupSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Choice {
        case deleteEffects
        case move(toGroupID: String)
    }

    let group: EffectGroup
    let destinationGroups: [EffectGroup]
    let onConfirm: (Choice) -> Void

    @State private var deleteEffects = false
    @State private var targetGroupID: String

    init(group: EffectGroup, destinationGroups: [EffectGroup], onConfirm: @escaping (Choice) -> Void) {
        self.group = group
        self.destinationGroups = destinationGroups
        self.onConfirm = onConfirm
        _targetGroupID = State(initialValue: destinationGroups.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \"\(group.name)\"?")
                .font(.headline)

            Text("This group contains \(group.effectIDs.count) effect(s).")
                .foregroundStyle(.secondary)

            Picker("What should happen to the effects?", selection: $deleteEffects) {
                Text("Move to another group").tag(false)
                Text("Delete all effects").tag(true)
            }
            .pickerStyle(.radioGroup)

            if !deleteEffects {
                Picker("Destination group", selection: $targetGroupID) {
                    ForEach(destinationGroups) { destination in
                        Text(destination.name).tag(destination.id)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Delete Group", role: .destructive) {
                    if deleteEffects {
                        onConfirm(.deleteEffects)
                    } else {
                        onConfirm(.move(toGroupID: targetGroupID))
                    }
                    dismiss()
                }
                .disabled(!deleteEffects && targetGroupID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct GroupHeaderRow: View {
    let group: EffectGroup
    let isExpanded: Bool
    let isEditing: Bool
    @Binding var editingName: String
    let canDelete: Bool
    let onToggleExpanded: () -> Void
    let onToggleEnabled: (Bool) -> Void
    let onStartEditing: () -> Void
    let onCommitEditing: () -> Void
    let onCancelEditing: () -> Void
    let onDelete: () -> Void
    var focusedGroupID: FocusState<String?>.Binding

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
            .help(isExpanded ? "Collapse group" : "Expand group")

            Toggle("", isOn: Binding(
                get: { group.enabled },
                set: onToggleEnabled
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            if isEditing {
                TextField("Group name", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .focused(focusedGroupID, equals: group.id)
                    .onSubmit(onCommitEditing)
                    .onExitCommand(perform: onCancelEditing)
            } else {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onStartEditing)
                    .help("Click to rename")
            }

            Spacer()

            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete group")
            }
        }
        .padding(.vertical, 2)
    }
}

struct EffectRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var effect: Effect
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
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

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove effect")
        }
    }
}
