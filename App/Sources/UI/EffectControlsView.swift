import AppKit
import ImageIO
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
    /// Decoded off the main thread. `NSImage(contentsOf:)` here reads the
    /// whole file during layout, and the controls pane is built on the click
    /// that opens it.
    @State private var preview: NSImage?

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

            if let preview {
                Image(nsImage: preview)
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
        .task(id: binding.mediaID) {
            guard let asset = assignedAsset, asset.kind == .image else {
                preview = nil
                return
            }
            let url = state.mediaLibrary.fileURL(for: asset)
            let cgImage = await Task.detached(priority: .userInitiated) {
                Self.downsampledPreview(at: url)
            }.value
            if Task.isCancelled { return }
            preview = cgImage.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
        }
    }

    /// A small preview, not the source file. The row is only 64pt tall.
    private static func downsampledPreview(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
