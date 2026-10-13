import Foundation

/// What the Light or Dark theme popup offers and shows. The popup shows the theme the engine draws
/// with, so a saved choice this Mac cannot honor (a theme synced from another Mac, a file that no
/// longer loads) is explained by a note and the saved setting is left alone.
internal struct ThemeSlotChoice: Equatable {
    internal enum Note: Equatable {
        case notOnThisMac(fallback: String)
        case wrongAppearance(theme: String, fallback: String)
    }

    internal let slot: ThemeAppearance
    internal let builtIn: [ThemeDefinition]
    internal let custom: [ThemeDefinition]
    internal let selectedId: String
    internal let note: Note?

    internal init(slot: ThemeAppearance, savedId: String, themes: [ThemeDefinition]) {
        self.slot = slot

        let fitting = themes.filter { $0.appearance == slot }
        builtIn = fitting.filter(\.isBuiltIn)
        custom = fitting.filter(\.isEditable)

        // The engine's own resolver, so the popup can never name a theme other than the one drawn.
        let inUse = ThemeResolver.resolve(
            mode: slot == .dark ? .dark : .light,
            lightThemeId: savedId,
            darkThemeId: savedId,
            themes: themes,
            systemIsDark: slot == .dark
        ).active
        selectedId = inUse.id

        if inUse.id == savedId {
            note = nil
        } else if let saved = themes.first(where: { $0.id == savedId }) {
            note = .wrongAppearance(theme: saved.name, fallback: inUse.name)
        } else {
            note = .notOnThisMac(fallback: inUse.name)
        }
    }

    internal var title: String {
        switch slot {
        case .light: return String(localized: "Light theme")
        case .dark: return String(localized: "Dark theme")
        }
    }

    internal var noteMessage: String? {
        guard let note else { return nil }
        switch (note, slot) {
        case let (.notOnThisMac(fallback), _):
            return String(format: String(localized: "The chosen theme is not on this Mac, so %@ is used."), fallback)
        case let (.wrongAppearance(theme, fallback), .light):
            return String(format: String(localized: "%1$@ is a dark theme, so %2$@ is used."), theme, fallback)
        case let (.wrongAppearance(theme, fallback), .dark):
            return String(format: String(localized: "%1$@ is a light theme, so %2$@ is used."), theme, fallback)
        }
    }
}
