import Foundation

internal struct ThemeSelection: Equatable, Sendable {
    internal let pair: ThemePair
    internal let effectiveAppearance: ThemeAppearance

    internal var active: ThemeDefinition { pair[effectiveAppearance] }
}

/// Pure. It never writes settings: a settings pane that rewrote the saved theme id to make its own
/// filter true silently replaced a theme the user had chosen and then hid it from the list they
/// would have used to put it back. A slot whose theme is missing, rejected, or of the wrong
/// appearance falls back to that slot's own built-in, so a broken dark theme never paints Default
/// Light inside dark chrome.
internal enum ThemeResolver {
    internal static func resolve(
        mode: AppAppearanceMode,
        lightThemeId: String,
        darkThemeId: String,
        themes: [ThemeDefinition],
        systemIsDark: Bool
    ) -> ThemeSelection {
        let pair = ThemePair(
            light: theme(id: lightThemeId, slot: .light, in: themes),
            dark: theme(id: darkThemeId, slot: .dark, in: themes)
        )

        return ThemeSelection(
            pair: pair,
            effectiveAppearance: effectiveAppearance(mode: mode, systemIsDark: systemIsDark)
        )
    }

    internal static func effectiveAppearance(mode: AppAppearanceMode, systemIsDark: Bool) -> ThemeAppearance {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .auto: return systemIsDark ? .dark : .light
        }
    }

    private static func theme(
        id: String,
        slot: ThemeAppearance,
        in themes: [ThemeDefinition]
    ) -> ThemeDefinition {
        guard let found = themes.first(where: { $0.id == id }), found.appearance == slot else {
            return BuiltInThemes.default(for: slot)
        }
        return found
    }
}

/// The list a slot offers. A theme only fits the slot whose appearance it declares, and the theme
/// the slot already holds stays listed so the user can always see and re-pick their own choice.
internal enum ThemeSlotValidation {
    internal static func fits(_ appearance: ThemeAppearance, slot: ThemeAppearance) -> Bool {
        appearance == slot
    }

    internal static func eligibleThemes(
        _ themes: [ThemeDefinition],
        slot: ThemeAppearance,
        keeping selectedId: String?
    ) -> [ThemeDefinition] {
        themes.filter { fits($0.appearance, slot: slot) || $0.id == selectedId }
    }
}
