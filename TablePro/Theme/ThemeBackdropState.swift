import AppKit
import TableProTheme

/// Whether the window backdrop draws the theme's color. Chrome over the backdrop asks this rather
/// than reading a slot: a bar keeps its material until the theme colors what is behind it.
@MainActor
internal enum ThemeBackdropState {
    internal static func isThemed(in appearance: NSAppearance, scope: ThemeScope = .live) -> Bool {
        isThemed(highContrast: appearance.isHighContrast, scope: scope)
    }

    /// For SwiftUI, which knows the contrast from its environment rather than from an appearance.
    internal static func isThemed(highContrast: Bool, scope: ThemeScope = .live) -> Bool {
        scope.activeTheme.isOverridden(.windowBackdrop, highContrast: highContrast)
    }
}
