import AppKit
import SwiftUI
import TableProTheme

// Chrome asks this rather than reading a slot: a bar keeps its material until the theme colors what is behind it.
@MainActor
internal enum ThemeBackdropState {
    internal static func isThemed(in appearance: NSAppearance, scope: ThemeScope = .live) -> Bool {
        isThemed(highContrast: appearance.isHighContrast, scope: scope)
    }

    internal static func isThemed(highContrast: Bool, scope: ThemeScope = .live) -> Bool {
        scope.activeTheme.isOverridden(.windowBackdrop, highContrast: highContrast)
    }

    // A sidebar or inspector takes the theme only through the window color, which reaches it from macOS 26.
    internal static func isThemed(
        highContrast: Bool,
        onSplitItem: Bool,
        reachesChrome: Bool = ThemeWindowBackdrop.canReachChrome,
        scope: ThemeScope = .live
    ) -> Bool {
        guard !onSplitItem || reachesChrome else { return false }
        return isThemed(highContrast: highContrast, scope: scope)
    }
}

private struct OnSplitItemKey: EnvironmentKey {
    static let defaultValue = false
}

internal extension EnvironmentValues {
    var isOnSplitItem: Bool {
        get { self[OnSplitItemKey.self] }
        set { self[OnSplitItemKey.self] = newValue }
    }
}

internal extension View {
    func onSplitItem() -> some View {
        environment(\.isOnSplitItem, true)
    }
}
