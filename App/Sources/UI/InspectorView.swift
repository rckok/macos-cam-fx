import AppKit
import SwiftUI

/// Effect-level controls: every `@metadata(global)` parameter its stages
/// declare. This is the only inspector Basic Mode shows.
struct EffectInspectorView: View {
    let effect: Effect
    @ObservedObject var store: EffectStore

    private var contributors: [Stage] {
        store.stages(in: effect).filter { !$0.globalParameters.isEmpty }
    }

    var body: some View {
        Form {
            if contributors.isEmpty {
                Section("Controls") {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if contributors.count == 1, let stage = contributors.first {
                Section("Controls") {
                    GlobalParameterControls(stage: stage)
                }
            } else {
                ForEach(contributors) { stage in
                    Section(stage.name) {
                        GlobalParameterControls(stage: stage)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var emptyMessage: String {
        if effect.stageIDs.isEmpty {
            return "This effect has no stages yet. Add one in Editor Mode."
        }
        return "No effect-level controls. Mark a stage parameter with `// @metadata(global)` to surface it here."
    }
}

/// The `global` parameters of one stage, edited in place on that stage.
private struct GlobalParameterControls: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: Stage

    var body: some View {
        ForEach(stage.globalParameters) { parameter in
            ParameterControl(parameter: binding(for: parameter)) {
                state.parametersChanged(stage)
            }
            .id("\(stage.id)-\(parameter.name)-\(parameter.type)-\(parameter.values.count)-\(parameter.isColor)")
        }
    }

    /// Writes straight back into the owning stage, matched by name so a
    /// recompile that reorders `Params` cannot scramble the controls.
    private func binding(for parameter: StageParameter) -> Binding<StageParameter> {
        Binding(
            get: { stage.parameters.first { $0.name == parameter.name } ?? parameter },
            set: { updated in
                guard let index = stage.parameters.firstIndex(where: { $0.name == parameter.name }) else { return }
                stage.parameters[index] = updated
            }
        )
    }
}

/// Auto-generated parameter controls reflected from the stage's Params block.
struct StageInspectorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: Stage

    var body: some View {
        Form {
            if !stage.textureBindings.isEmpty {
                Section("Textures") {
                    ForEach($stage.textureBindings) { $binding in
                        TextureBindingRow(stage: stage, binding: $binding)
                    }
                }
            }

            Section("Parameters") {
                if stage.parameters.isEmpty {
                    Text("No scalar parameters.\nDeclare a `Params` uniform block to add sliders and toggles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($stage.parameters) { $parameter in
                        ParameterControl(parameter: $parameter) {
                            state.parametersChanged(stage)
                        }
                        .id("\(parameter.name)-\(parameter.type)-\(parameter.values.count)-\(parameter.isColor)")
                    }
                }
            }

            if stage.textureBindings.isEmpty && stage.parameters.isEmpty {
                Text("Declare a `Params` block and/or `sampler2D` uniforms (binding ≥ 4) in your shader.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Inspector")
    }
}

private struct TextureBindingRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: Stage
    @Binding var binding: StageTextureBinding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(binding.name)
                .font(.headline)

            Picker("Media", selection: mediaSelection) {
                Text("None").tag(Optional<String>.none)
                ForEach(state.mediaLibrary.assets) { asset in
                    Text(asset.displayName).tag(Optional(asset.id))
                }
            }
            .labelsHidden()

            if let asset = assignedAsset, asset.kind == .image,
               let image = NSImage(contentsOf: state.mediaLibrary.fileURL(for: asset)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if assignedAsset != nil {
                Label(assignedAsset!.kind == .video ? "Video" : "Image", systemImage: assignedAsset!.kind == .video ? "film" : "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var assignedAsset: MediaAsset? {
        guard let mediaID = binding.mediaID else { return nil }
        return state.mediaLibrary.asset(id: mediaID)
    }

    private var mediaSelection: Binding<String?> {
        Binding(
            get: { binding.mediaID },
            set: { newValue in
                state.assignMedia(newValue, toSampler: binding.name, in: stage)
            }
        )
    }
}

struct ParameterControl: View {
    @Binding var parameter: StageParameter
    let onChange: () -> Void

    var body: some View {
        switch parameter.editorKind {
        case .floatSliders(let componentCount):
            if componentCount == 1 {
                EditableFloatSlider(
                    title: parameter.name,
                    value: componentBinding(0),
                    range: parameter.sliderRange(at: 0)
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(parameter.name)
                    ForEach(0..<componentCount, id: \.self) { index in
                        EditableFloatSlider(
                            title: componentLabel(index),
                            value: componentBinding(index),
                            range: parameter.sliderRange(at: index)
                        )
                    }
                }
            }
        case .intSlider:
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(parameter.name) {
                    Text("\(Int(parameter.values[0]))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { parameter.values[0] },
                        set: { parameter.values[0] = $0.rounded(); onChange() }
                    ),
                    in: parameter.sliderRange(at: 0, step: 1),
                    step: 1
                )
            }
        case .toggle(let componentCount):
            if componentCount == 1 {
                Toggle(isOn: boolBinding(index: 0)) {
                    Text(parameter.name)
                }
                .toggleStyle(.switch)
            } else {
                LabeledContent(parameter.name) {
                    HStack(spacing: 12) {
                        ForEach(0..<componentCount, id: \.self) { index in
                            Toggle(componentLabel(index), isOn: boolBinding(index: index))
                                .toggleStyle(.switch)
                        }
                    }
                }
            }
        case .color(let supportsOpacity):
            ColorPicker(
                parameter.name,
                selection: Binding(
                    get: {
                        Color(
                            red: parameter.values[0],
                            green: parameter.values.count > 1 ? parameter.values[1] : 0,
                            blue: parameter.values.count > 2 ? parameter.values[2] : 0,
                            opacity: parameter.values.count > 3 ? parameter.values[3] : 1
                        )
                    },
                    set: { color in
                        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
                        parameter.values[0] = Double(resolved.redComponent)
                        if parameter.values.count > 1 { parameter.values[1] = Double(resolved.greenComponent) }
                        if parameter.values.count > 2 { parameter.values[2] = Double(resolved.blueComponent) }
                        if parameter.values.count > 3 { parameter.values[3] = Double(resolved.alphaComponent) }
                        onChange()
                    }
                ),
                supportsOpacity: supportsOpacity
            )
        case .unsupported(let typeName):
            LabeledContent(parameter.name) {
                Text(typeName).foregroundStyle(.secondary)
            }
        }
    }

    private func boolBinding(index: Int) -> Binding<Bool> {
        Binding(
            get: { parameter.values[index] != 0 },
            set: { parameter.values[index] = $0 ? 1 : 0; onChange() }
        )
    }

    private func componentBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { parameter.values[index] },
            set: { parameter.values[index] = $0; onChange() }
        )
    }

    private func componentLabel(_ index: Int) -> String {
        switch index {
        case 0: "x"
        case 1: "y"
        case 2: "z"
        case 3: "w"
        default: "\(index)"
        }
    }
}

/// Slider plus a text field so values can be typed precisely.
private struct EditableFloatSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: $value, in: range) { editing in
                if editing { isFocused = false }
            }
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .focused($isFocused)
                .onSubmit(commitDraft)
                .accessibilityLabel(title)
        }
        .onAppear { draft = Self.format(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused { draft = Self.format(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitDraft() }
        }
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Double(trimmed) ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
        if let parsed {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            if clamped != value { value = clamped }
            draft = Self.format(clamped)
        } else {
            draft = Self.format(value)
        }
    }

    private static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.contains("."), text.last == "0" {
            text.removeLast()
        }
        if text.last == "." { text.removeLast() }
        return text
    }
}
