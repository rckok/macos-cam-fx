import SwiftUI

/// GLSL source editor with live recompile and inline diagnostics.
struct EditorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var effect: Effect
    @State private var revealLine: Int?
    @State private var revealNonce = 0

    private var errorCount: Int {
        effect.diagnostics.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        effect.diagnostics.filter { $0.severity == .warning }.count
    }

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
                statusLabel
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Color(nsColor: .textBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    ShaderSourceEditor(
                        text: effect.source,
                        diagnostics: effect.diagnostics,
                        revealLine: revealLine,
                        revealNonce: revealNonce,
                        onChange: handleEditorChange
                    )
                }

            if !effect.diagnostics.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(effect.diagnostics) { diagnostic in
                            Button {
                                guard let line = diagnostic.line else { return }
                                revealLine = line
                                revealNonce += 1
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: diagnostic.severity == .error
                                          ? "xmark.octagon.fill"
                                          : "exclamationmark.triangle.fill")
                                        .foregroundStyle(diagnostic.severity == .error ? .red : .yellow)
                                        .font(.caption)
                                    if let line = diagnostic.line {
                                        Text("Line \(line):")
                                            .font(.caption.monospacedDigit().bold())
                                    }
                                    Text(diagnostic.message)
                                        .font(.caption)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(diagnostic.line == nil)
                            .help(diagnostic.line == nil ? diagnostic.message : "Jump to line \(diagnostic.line!)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 100)
                .background((errorCount > 0 ? Color.red : Color.yellow).opacity(0.06))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if errorCount > 0 {
            Label("\(errorCount) error\(errorCount == 1 ? "" : "s")", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        } else if warningCount > 0 {
            Label("\(warningCount) warning\(warningCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
        } else {
            Label("Compiled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }

    private func handleEditorChange(_ newText: String) {
        DispatchQueue.main.async {
            guard effect.source != newText else { return }
            effect.source = newText
            state.scheduleCompile(effect, debounce: true)
        }
    }
}
