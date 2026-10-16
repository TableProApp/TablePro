import Foundation

public struct ThemePair: Equatable, Sendable {
    public var light: ThemeDefinition
    public var dark: ThemeDefinition

    public static let builtIn = ThemePair(light: .defaultLight, dark: .defaultDark)

    public init(light: ThemeDefinition, dark: ThemeDefinition) {
        self.light = light
        self.dark = dark
    }

    public subscript(appearance: ThemeAppearance) -> ThemeDefinition {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }
}

public struct ThemeSelection: Equatable, Sendable {
    public let pair: ThemePair
    public let effectiveAppearance: ThemeAppearance

    public init(pair: ThemePair, effectiveAppearance: ThemeAppearance) {
        self.pair = pair
        self.effectiveAppearance = effectiveAppearance
    }

    public var active: ThemeDefinition {
        pair[effectiveAppearance]
    }
}

/// Pure. It never writes settings: a settings pane that rewrote the saved theme id to make its own
/// filter true silently replaced a theme the user had chosen and then hid it from the list they
/// would have used to put it back. A slot whose theme is missing, rejected, or of the wrong
/// appearance falls back to that slot's own default, so a broken dark theme never paints Default
/// Light inside dark chrome.
public enum ThemeResolver {
    public static func resolve(
        lightThemeId: String,
        darkThemeId: String,
        themes: [ThemeDefinition],
        effectiveAppearance: ThemeAppearance
    ) -> ThemeSelection {
        let pair = ThemePair(
            light: theme(id: lightThemeId, slot: .light, in: themes),
            dark: theme(id: darkThemeId, slot: .dark, in: themes)
        )
        return ThemeSelection(pair: pair, effectiveAppearance: effectiveAppearance)
    }

    private static func theme(id: String, slot: ThemeAppearance, in themes: [ThemeDefinition]) -> ThemeDefinition {
        guard let found = themes.first(where: { $0.id == id }), found.appearance == slot else {
            return .default(for: slot)
        }
        return found
    }
}

/// The list a slot offers. A theme only fits the slot whose appearance it declares, and the theme
/// the slot already holds stays listed so the user can always see and re-pick their own choice.
public enum ThemeSlotValidation {
    public static func fits(_ appearance: ThemeAppearance, slot: ThemeAppearance) -> Bool {
        appearance == slot
    }

    public static func eligibleThemes(
        _ themes: [ThemeDefinition],
        slot: ThemeAppearance,
        keeping selectedId: String?
    ) -> [ThemeDefinition] {
        themes.filter { fits($0.appearance, slot: slot) || $0.id == selectedId }
    }
}
