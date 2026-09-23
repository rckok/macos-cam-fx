import AppKit
import SwiftUI

// Liquid Glass only exists in the macOS 26 SDK, which ships with Swift 6.2, so
// every reference to it sits behind `#if compiler(>=6.2)` to keep the project
// building on older Xcode releases, and behind `#available` to keep the app
// running on its macOS 14 deployment target. Everything glass-related lives in
// this file so the rest of the UI never repeats those two checks.

/// Groups the glass surfaces of a window so they blend with each other instead
/// of sampling each other, and so nearby ones merge as they move. Wrap the
/// window's content in one of these once; nesting them defeats the blending
/// between the groups. A nested one is also where glass gets *drawn*, which
/// is what keeps the editor panel's chrome inside the panel's clip.
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
    /// A chrome strip that floats above content: a panel header, the stage
    /// list's bottom bar, the editor's diagnostics list. `tint` colors the glass
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
    /// the camera view in Basic Mode.
    ///
    /// This is the *clear* glass style, not the frosted `regular` one used for
    /// app chrome: it is the style meant for controls over photos and video,
    /// and it lets far more of the feed through. Clear glass does no work to
    /// keep what sits on it legible, so a surface carrying small text or
    /// controls should pass a `dim` — a scrim between the glass and the
    /// content, which is how Apple's own media controls stay readable over a
    /// bright frame.
    ///
    /// `interactive` gives a control the lift and stretch of a glass button on
    /// hover and press; leave it off for labels.
    ///
    /// Panes that should read as system menus use `menuSurface` instead.
    /// Clear glass takes its tone from the feed, so over video it stays dark
    /// and does not follow the OS appearance the way a menu does.
    func glassSurface(in shape: some Shape, interactive: Bool = false, dim: Double = 0) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, dim: dim))
    }

    /// A floating pane drawn like a system menu: frosted, and light or dark
    /// with the OS, rather than the clear glass of the controls over the camera.
    /// The pane must not sit inside a forced dark color scheme, or it will
    /// stop tracking the appearance the menus use.
    func menuSurface(in shape: some Shape) -> some View {
        modifier(MenuSurface(shape: shape))
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let dim: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // The scrim goes on before the glass, so it lands between the
            // glass and the content rather than over either.
            dimmed(content)
                .glassEffect(.clear.interactive(interactive), in: shape)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func dimmed(_ content: Content) -> some View {
        content.background(Color.black.opacity(dim), in: shape)
    }

    /// `.ultraThinMaterial` is the closest the pre-26 materials get to clear
    /// glass; the shadow stands in for the lensing that separates glass from
    /// the content behind it.
    private func legacy(_ content: Content) -> some View {
        dimmed(content)
            .background(.ultraThinMaterial, in: shape)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// Regular glass is the macOS 26 surface that matches a system menu: frosted,
/// and light or dark with the appearance, unlike the clear glass that takes
/// its tone from the feed. The caller passes the menu's corner. Before macOS
/// 26, the menu material is the surface `NSMenu` draws.
private struct MenuSurface<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // The glass effect supplies the menu's edge and separation.
            // A view shadow on top of it would also shadow the pane's text.
            content.glassEffect(.regular, in: shape)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    /// The shadow is the menu window's, which `NSVisualEffectView` does not draw.
    private func legacy(_ content: Content) -> some View {
        content
            .background {
                MenuMaterialFill()
                    .clipShape(shape)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }
}

/// The material `NSMenu` uses on systems before the macOS 26 menu glass.
private struct MenuMaterialFill: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        // Sample the camera behind the pane, the way a menu window samples
        // whatever it was opened over.
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
