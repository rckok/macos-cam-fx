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

            // Color expands in the split view; NSViewRepresentable overlay then
            // fills that frame. Without this, the AppKit view often lays out at 0×0.
            Color(nsColor: .textBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    ShaderSourceEditor(
                        text: effect.source,
                        onChange: handleEditorChange
                    )
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleEditorChange(_ newText: String) {
        DispatchQueue.main.async {
            guard effect.source != newText else { return }
            effect.source = newText
            state.scheduleCompile(effect, debounce: true)
        }
    }
}
