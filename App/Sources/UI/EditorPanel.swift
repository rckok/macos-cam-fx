import AppKit
import SwiftUI

/// Editor Mode's panel, which slides up under the camera: the active effect's
/// stages on the left, the GLSL editor for the selected stage on the right.
/// Controls are not here — the floating controls pane over the camera shows
/// the selected stage's while the panel is open.
struct EditorPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: EffectStore

    var body: some View {
        HSplitView {
            if let effect = state.activeEffect {
                StageListView(store: store, effect: effect)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 400)
                    .layoutPriority(0)
            } else {
                noEffect
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 400)
                    .layoutPriority(0)
            }

            editorColumn
                .frame(minWidth: 320)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Separates the panel from the camera above it — and from the glass
        // over the camera, which would otherwise seem to run into the panel.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var editorColumn: some View {
        if let stage = state.selectedStage {
            EditorView(stage: stage)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("No Stage Selected")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    EditorToolButtons()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .glassChrome()

                ContentUnavailableView(
                    "No Stage Selected",
                    systemImage: "wand.and.stars",
                    description: Text(state.activeEffect == nil
                                      ? "Choose an effect to edit its stages."
                                      : "Select a stage on the left, or add one to the effect.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var noEffect: some View {
        VStack(spacing: 0) {
            HStack {
                Text("No Effect")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .glassChrome()

            Spacer()

            Button {
                state.addEffect()
            } label: {
                Label("New Effect", systemImage: "plus")
            }

            Spacer()
        }
    }
}

/// The editor's tools: the built-in uniforms reference, the shared media
/// library, and the settings only editing needs (frame history). They used
/// to be toolbar items; the window has no toolbar now that the camera runs
/// to its top edge in both modes.
struct EditorToolButtons: View {
    @EnvironmentObject private var state: AppState
    @State private var showUniforms = false
    @State private var showMediaLibrary = false
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 4) {
            toolButton("curlybraces", help: "Built-in shader uniforms") {
                showUniforms.toggle()
            }
            .popover(isPresented: $showUniforms) {
                ShaderGlobalsView()
            }

            toolButton("photo.on.rectangle.angled", help: "Open the shared media library") {
                showMediaLibrary.toggle()
            }
            .popover(isPresented: $showMediaLibrary) {
                MediaLibraryView()
                    .environmentObject(state)
            }

            toolButton("gearshape", help: "Settings") {
                showSettings.toggle()
            }
            .popover(isPresented: $showSettings) {
                SettingsPopover()
                    .environmentObject(state)
            }
        }
    }

    private func toolButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// The grab strip along the top edge of the editor panel. Dragging it up
/// gives the panel more of the window; the camera above takes the rest.
struct PanelResizeHandle: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var heightAtDragStart: CGFloat?

    var body: some View {
        Color.clear
            .frame(height: 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = heightAtDragStart ?? height
                        heightAtDragStart = start
                        // Up is negative in view coordinates, and up grows the panel.
                        height = (start - value.translation.height).clamped(to: range)
                    }
                    .onEnded { _ in
                        heightAtDragStart = nil
                    }
            )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
