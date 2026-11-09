import AppKit
import SwiftUI
import TableProTheme

// Under Reduce Transparency the sidebar and inspector glass draws an opaque system fill that drops the
// window color, so the pane draws `window.background` itself until the glass comes back.
@MainActor
internal enum SplitItemBackdrop {
    internal static func fills(reachesChrome: Bool, reduceTransparency: Bool, isThemed: Bool) -> Bool {
        reachesChrome && reduceTransparency && isThemed
    }

    internal static func makeView(reduceTransparency: Bool? = nil) -> NSView {
        let view = SplitItemBackdropView(rootView: SplitItemBackdropSurface(reduceTransparency: reduceTransparency))
        view.sizingOptions = []
        return view
    }
}

internal struct SplitItemBackdropFill: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    // The environment value is get-only, so a test hands its own.
    internal var reduceTransparency: Bool?
    internal var reachesChrome = ThemeWindowBackdrop.canReachChrome

    internal func body(content: Content) -> some View {
        let fills = SplitItemBackdrop.fills(
            reachesChrome: reachesChrome,
            reduceTransparency: reduceTransparency ?? systemReduceTransparency,
            isThemed: ThemeBackdropState.isThemed(highContrast: contrast == .increased)
        )
        return content.background(
            fills ? AnyShapeStyle(Color(nsColor: themeEngine.palette[.windowBackdrop])) : AnyShapeStyle(Color.clear),
            ignoresSafeAreaEdges: .all
        )
    }
}

internal extension View {
    func splitItemBackdrop() -> some View {
        modifier(SplitItemBackdropFill())
    }
}

private struct SplitItemBackdropSurface: View {
    let reduceTransparency: Bool?

    var body: some View {
        Color.clear
            .modifier(SplitItemBackdropFill(reduceTransparency: reduceTransparency))
            .accessibilityHidden(true)
    }
}

// A point the pane above leaves unclaimed still reaches the glass and the window.
private final class SplitItemBackdropView: NSHostingView<SplitItemBackdropSurface> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
