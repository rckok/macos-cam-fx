import SwiftUI

/// Auto-generated parameter controls reflected from the effect's Params block.
struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var effect: Effect

    var body: some View {
        Form {
            if effect.parameters.isEmpty {
                Text("This effect has no parameters.\nDeclare a `Params` uniform block in the shader to add some.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($effect.parameters) { $parameter in
                    ParameterControl(parameter: $parameter) {
                        state.parametersChanged(effect)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Parameters")
    }
}

struct ParameterControl: View {
    @Binding var parameter: EffectParameter
    let onChange: () -> Void

    var body: some View {
        switch parameter.type {
        case "float":
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(parameter.name) {
                    Text(String(format: "%.3f", parameter.values[0]))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { parameter.values[0] },
                        set: { parameter.values[0] = $0; onChange() }
                    ),
                    in: parameter.minimum...max(parameter.maximum, parameter.minimum + 0.0001)
                )
            }
        case "int":
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
                    in: parameter.minimum...max(parameter.maximum, parameter.minimum + 1),
                    step: 1
                )
            }
        case "bool":
            Toggle(parameter.name, isOn: Binding(
                get: { parameter.values[0] != 0 },
                set: { parameter.values[0] = $0 ? 1 : 0; onChange() }
            ))
        case "vec2":
            LabeledContent(parameter.name) {
                HStack {
                    componentField(index: 0, label: "x")
                    componentField(index: 1, label: "y")
                }
            }
        case "vec3", "vec4":
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
                supportsOpacity: parameter.type == "vec4"
            )
        default:
            LabeledContent(parameter.name) {
                Text(parameter.type).foregroundStyle(.secondary)
            }
        }
    }

    private func componentField(index: Int, label: String) -> some View {
        TextField(label, value: Binding(
            get: { parameter.values[index] },
            set: { parameter.values[index] = $0; onChange() }
        ), format: .number)
        .textFieldStyle(.roundedBorder)
        .frame(width: 64)
    }
}
