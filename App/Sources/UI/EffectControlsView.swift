import AppKit
import SwiftUI

/// Effect-level controls: every `@metadata(global)` parameter and sampler its
/// stages declare. A plain stack rather than a grouped form, because it lives
/// in the floating controls pane, where a form's own scrolling and
/// backgrounds would fight the glass.
struct EffectControls: View {
    let effect: Effect
    @ObservedObject var store: EffectStore

    private var contributors: [Stage] {
        store.controlStages(in: effect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if contributors.isEmpty {
                Text(Self.emptyMessage(for: effect))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contributors) { stage in
                    if contributors.count > 1 {
                        Text(stage.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    GlobalControls(stage: stage)
                }
            }
        }
    }

    static func emptyMessage(for effect: Effect) -> String {
        if effect.stageIDs.isEmpty {
            return "This effect has no stages yet. Open the editor to add one."
        }
        return "No effect-level controls. Mark a stage parameter or sampler with `// @metadata(global)` to surface it here."
    }
}

/// Every control of one stage — its samplers and all of its parameters,
/// `global` or not — for the editor panel's stage controls column.
struct StageControls: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: Stage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if stage.kind == .geometry {
                GeometryControls(stage: stage)
                Divider()
            }

            if stage.textureBindings.isEmpty && stage.parameters.isEmpty {
                Text("No controls. Declare a `Params` uniform block for sliders and toggles, or `sampler2D` uniforms (binding ≥ 4) for media pickers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($stage.textureBindings) { $binding in
                TextureBindingRow(stage: stage, binding: $binding)
            }

            ForEach($stage.parameters) { $parameter in
                ParameterControl(parameter: $parameter) {
                    state.parametersChanged(stage)
                }
                .id("\(parameter.name)-\(parameter.type)-\(parameter.values.count)-\(parameter.isColor)")
            }
        }
    }
}

/// A geometry stage's own controls: what it draws, how it combines with the
/// frame, and its simulation pass.
private struct GeometryControls: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: Stage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Geometry")
                .font(.headline)

            Picker("Primitive", selection: setting(\.primitive)) {
                ForEach(GeometryPrimitive.allCases) { primitive in
                    Text(primitive.title).tag(primitive)
                }
            }
            .help("What each run of Vertices per item vertices draws. Strips connect within one item only.")

            IntegerField(title: "Count", value: setting(\.count), range: GeometrySettings.countRange)
                .help("Items drawn — and simulated, with a simulation pass. ceItemIndex runs 0 … Count − 1.")
            IntegerField(
                title: "Vertices per item",
                value: setting(\.verticesPerItem),
                range: GeometrySettings.verticesPerItemRange
            )
            .help("Vertices the Vertex tab runs for each item; ceVertexIndex runs 0 … this − 1. 1 for points, 2 for a line, 6 for a quad.")

            Picker("Start from", selection: setting(\.startFrom)) {
                ForEach(GeometryStartFrom.allCases) { start in
                    Text(start.title).tag(start)
                }
            }
            .help("What the stage's texture holds before the geometry is drawn each frame. Own Last Frame keeps everything drawn so far.")

            Picker("Blend", selection: setting(\.blend)) {
                ForEach(GeometryBlend.allCases) { blend in
                    Text(blend.title).tag(blend)
                }
            }
            .help("How outColor combines with what is already there: overwrite it, mix by alpha, or add to it.")

            Toggle("Simulation", isOn: setting(\.simulation))
                .toggleStyle(.switch)
                .disabled(stage.isBuiltIn)
                .help("Adds a Simulation tab that updates 32-bit float state for every item before each draw; read it with ceState().")

            if stage.geometry.simulation {
                Stepper(value: setting(\.stateSlots), in: GeometrySettings.stateSlotRange) {
                    LabeledContent("State slots") {
                        Text("\(stage.geometry.stateSlots)")
                            .monospacedDigit()
                    }
                }
                .disabled(stage.isBuiltIn)
                .help("vec4 values per item: outState0 … outState\(GeometrySettings.stateSlotRange.upperBound - 1), read back with ceState(slot, index).")

                Stepper(value: setting(\.substeps), in: GeometrySettings.substepRange) {
                    LabeledContent("Substeps") {
                        Text("\(stage.geometry.substeps)")
                            .monospacedDigit()
                    }
                }
                .help("Simulation steps per frame. uSimDelta is the frame's time split evenly between them.")

                Button("Reset Simulation") {
                    state.resetSimulation(stage)
                }
                .help("Start again from zeroed state, with uSimFrame back at 0. Changing Count or State slots also resets.")
            }
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<GeometrySettings, Value>) -> Binding<Value> {
        Binding(
            get: { stage.geometry[keyPath: keyPath] },
            set: { newValue in
                var geometry = stage.geometry
                geometry[keyPath: keyPath] = newValue
                state.setGeometry(geometry, for: stage)
            }
        )
    }
}

/// A whole number typed in, applied on Return or when the field loses focus.
private struct IntegerField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { value },
                set: { value = $0.clamped(to: range) }
            ), format: .number)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(maxWidth: 110)
        }
    }
}

/// The `global` controls of one stage, edited in place on that stage.
private struct GlobalControls: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: Stage

    var body: some View {
        ForEach(stage.globalTextureBindings) { binding in
            TextureBindingRow(stage: stage, binding: textureBinding(for: binding))
        }

        ForEach(stage.globalParameters) { parameter in
            ParameterControl(parameter: parameterBinding(for: parameter)) {
                state.parametersChanged(stage)
            }
            .id("\(stage.id)-\(parameter.name)-\(parameter.type)-\(parameter.values.count)-\(parameter.isColor)")
        }
    }

    /// Writes straight back into the owning stage, matched by name so a
    /// recompile that reorders `Params` cannot scramble the controls.
    private func parameterBinding(for parameter: StageParameter) -> Binding<StageParameter> {
        Binding(
            get: { stage.parameters.first { $0.name == parameter.name } ?? parameter },
            set: { updated in
                guard let index = stage.parameters.firstIndex(where: { $0.name == parameter.name }) else { return }
                stage.parameters[index] = updated
            }
        )
    }

    private func textureBinding(for binding: StageTextureBinding) -> Binding<StageTextureBinding> {
        Binding(
            get: { stage.textureBindings.first { $0.name == binding.name } ?? binding },
            set: { updated in
                guard let index = stage.textureBindings.firstIndex(where: { $0.name == binding.name }) else { return }
                stage.textureBindings[index] = updated
            }
        )
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
