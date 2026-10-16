import SwiftUI

/// A bar's material is drawn for the system window color, so over a themed backdrop it reads as a
/// system band. The bar then draws nothing and shows the pane's theme through it.
private struct PaneBarBackground<Native: ShapeStyle>: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    let native: Native
    let edges: Edge.Set

    func body(content: Content) -> some View {
        let isThemed = ThemeBackdropState.isThemed(highContrast: contrast == .increased)
        return content.background(
            isThemed ? AnyShapeStyle(Color.clear) : AnyShapeStyle(native),
            ignoresSafeAreaEdges: edges
        )
    }
}

internal extension View {
    /// No edges by default: a bar at the top of a pane would otherwise reach under the toolbar and
    /// pull its glass toward the bar's material.
    func paneBarBackground(_ native: some ShapeStyle = .bar, ignoresSafeAreaEdges edges: Edge.Set = []) -> some View {
        modifier(PaneBarBackground(native: native, edges: edges))
    }
}
