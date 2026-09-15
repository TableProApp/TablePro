import SwiftUI

/// Re-resolves `.secondary` and `.tertiary` inside a content pane to the theme's own text levels,
/// which is how 184 hierarchical foreground styles across the content surfaces follow a theme
/// without each one being rewritten.
///
/// It never branches on the theme. `WorkspacePanes` depends on every pane builder erasing one
/// stable view identity, so an `if` here would tear down the grid, the editor's undo stack and the
/// scroll position on a theme change. It reads the engine inside `body`, so the palette it applies
/// is the current one rather than whatever was captured when the pane was built.
private struct ThemedContentSurface: ViewModifier {
    func body(content: Content) -> some View {
        let palette = ThemeEngine.shared.palette

        return content.foregroundStyle(
            palette.color(.panelText),
            palette.color(.panelSecondaryText),
            palette.color(.panelTertiaryText)
        )
    }
}

internal extension View {
    func themedContent() -> some View {
        modifier(ThemedContentSurface())
    }
}
