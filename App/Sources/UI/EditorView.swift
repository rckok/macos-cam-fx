import SwiftUI

/// GLSL source editor with live recompile and inline diagnostics.
struct EditorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var effect: Effect

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Effect name", text: $effect.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit {
                        state.store.persist(effect: effect)
                    }
                Spacer()
                if effect.diagnostics.isEmpty {
                    Label("Compiled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("\(effect.diagnostics.count) error(s)", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            TextEditor(text: $effect.source)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .autocorrectionDisabled()
                .onChange(of: effect.source) {
                    state.scheduleCompile(effect, debounce: true)
                }

            if !effect.diagnostics.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(effect.diagnostics) { diagnostic in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                if let line = diagnostic.line {
                                    Text("Line \(line):")
                                        .font(.caption.monospacedDigit().bold())
                                }
                                Text(diagnostic.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 100)
                .background(Color.red.opacity(0.06))
            }
        }
    }
}
