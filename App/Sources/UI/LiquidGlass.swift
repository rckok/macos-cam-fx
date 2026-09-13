import SwiftUI

// Liquid Glass only exists in the macOS 26 SDK, which ships with Swift 6.2, so
// every reference to it sits behind `#if compiler(>=6.2)` to keep the project
// building on older Xcode releases, and behind `#available` to keep the app
// running on its macOS 14 deployment target. Everything glass-related lives in
// this file so the rest of the UI never repeats those two checks.

/// Groups the glass surfaces of a window so they blend with each other instead
/// of sampling each other, and so nearby ones merge as they move. Wrap the
/// window's content in one of these once; nesting them defeats the blending.
struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

extension View {
    /// A chrome strip that floats above content: a panel header, the sidebar's
    /// bottom bar, the editor's diagnostics list. `tint` colors the glass
    /// itself, which is how the diagnostics list reads as an error or warning.
    ///
    /// Chrome is the only thing that should carry glass here — putting it on a
    /// column background too would stack glass on glass, which reads as murk.
    func glassChrome(tint: Color? = nil) -> some View {
        modifier(GlassChrome(tint: tint))
    }

    /// A button that belongs to a glass strip: a glass capsule on macOS 26,
    /// and the borderless button it used to be before that.
    func glassChromeButton() -> some View {
        modifier(GlassChromeButton())
    }

    /// A free-floating glass element over content — the controls that sit on
    /// the camera view in Basic Mode. `interactive` gives a control the lift
    /// and stretch of a glass button on hover and press; leave it off for
    /// panes. Falls back to a plain material with a soft shadow.
    func glassSurface(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

private struct GlassChrome: ViewModifier {
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: .rect)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var glass: Glass {
        guard let tint else { return .regular }
        return .regular.tint(tint)
    }
    #endif

    @ViewBuilder
    private func legacy(_ content: Content) -> some View {
        content.background {
            Rectangle()
                .fill(.bar)
                .overlay(tint?.opacity(0.06) ?? Color.clear)
        }
    }
}

private struct GlassChromeButton: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderless)
        }
        #else
        content.buttonStyle(.borderless)
        #endif
    }
}
