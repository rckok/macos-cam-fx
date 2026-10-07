import SwiftUI

/// GLSL source editor with live recompile and inline diagnostics.
struct EditorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: Stage
    @State private var revealLine: Int?
    @State private var revealNonce = 0
    /// The tab picked for a geometry stage; nil, or a tab the stage no
    /// longer has, falls back to its Vertex tab.
    @State private var chosenFile: ShaderFile?

    private var currentFile: ShaderFile {
        if let chosenFile, stage.files.contains(chosenFile) { return chosenFile }
        return stage.kind == .geometry ? .vertex : .fragment
    }

    /// Diagnostics whose lines belong to the file in the editor.
    private var fileDiagnostics: [ShaderDiagnostic] {
        stage.allDiagnostics.filter { $0.file == currentFile }
    }

    private var errorCount: Int {
        stage.allDiagnostics.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        stage.allDiagnostics.filter { $0.severity == .warning }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if stage.isBuiltIn {
                    Text(stage.name)
                        .font(.headline)
                    Label("Built-in", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .help("Built-in stages are read-only. Duplicate the effect to Custom to edit a copy.")
                    if let effect = state.store.effect(containing: stage.id) {
                        Button("Duplicate to Custom") {
                            state.duplicateEffect(effect)
                        }
                        .controlSize(.small)
                        .help("Copy \"\(effect.name)\" and its stages into Custom effects, where they can be edited")
                    }
                } else {
                    TextField("Stage name", text: $stage.name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .onSubmit {
                            state.store.persist(stage: stage)
                            // Other stages may reference this one by name.
                            state.rebuildChain()
                        }
                }
                Spacer()
                if stage.isShadowed {
                    Label("Not rendered", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .help(Stage.shadowedExplanation)
                }
                statusLabel
                EditorToolButtons()
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .glassChrome()

            if stage.kind == .geometry {
                fileTabs
            }

            Color(nsColor: .textBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    let file = currentFile
                    ShaderSourceEditor(
                        text: stage.text(of: file),
                        diagnostics: fileDiagnostics,
                        revealLine: revealLine,
                        revealNonce: revealNonce,
                        isEditable: !stage.isBuiltIn,
                        onChange: { handleEditorChange($0, file: file) }
                    )
                    // One editor per file, so undo never crosses files.
                    .id(file)
                }

            if !stage.allDiagnostics.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(stage.allDiagnostics) { diagnostic in
                            Button {
                                if stage.kind == .geometry {
                                    chosenFile = diagnostic.file
                                }
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
                                    if stage.kind == .geometry {
                                        Text("\(diagnostic.file.title):")
                                            .font(.caption.bold())
                                    }
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
                            .disabled(diagnostic.line == nil && stage.kind != .geometry)
                            .help(diagnostic.line == nil ? diagnostic.message : "Jump to line \(diagnostic.line!)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 100)
                // The tint is the status: glass carries it without covering
                // the list in a wash of color.
                .glassChrome(tint: errorCount > 0 ? .red : .yellow)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: stage.id) { _, _ in
            chosenFile = nil
        }
    }

    /// Simulation (while it is on), Vertex and Fragment. A tab with errors
    /// carries their count.
    private var fileTabs: some View {
        Picker("Shader", selection: Binding(
            get: { currentFile },
            set: { file in
                // The new tab's editor would otherwise reveal the last line
                // jumped to in another file.
                revealLine = nil
                chosenFile = file
            }
        )) {
            ForEach(stage.files) { file in
                Text(tabTitle(for: file)).tag(file)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassChrome()
    }

    private func tabTitle(for file: ShaderFile) -> String {
        let errors = stage.allDiagnostics.filter { $0.file == file && $0.severity == .error }.count
        return errors > 0 ? "\(file.title) (\(errors))" : file.title
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

    private func handleEditorChange(_ newText: String, file: ShaderFile) {
        DispatchQueue.main.async {
            guard !stage.isBuiltIn, stage.text(of: file) != newText else { return }
            stage.setText(newText, of: file)
            state.scheduleCompile(stage, debounce: true)
        }
    }
}
