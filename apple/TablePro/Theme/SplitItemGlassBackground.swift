import SwiftUI

/// From macOS 26 a sidebar or inspector split item is glass, which takes its tone from the window
/// color. A `List` puts its own content-background material over that glass, and that material
/// never follows the window color, so it reads as a second surface inside the pane. Apple's
/// guidance for the new design is to remove such effect views so the glass shows through.
///
/// The condition is fixed for the process: SwiftUI never puts the material back when a list's
/// scroll background goes from hidden to automatic at runtime, measured.
private struct SplitItemGlassBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if ThemeWindowBackdrop.canReachChrome {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

internal extension View {
    /// For a list or scroll view filling a sidebar or inspector split item.
    func splitItemGlassBackground() -> some View {
        modifier(SplitItemGlassBackground())
    }
}
