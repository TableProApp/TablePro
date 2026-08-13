//
//  ThemeSlotValidation.swift
//  TablePro
//

import Foundation

/// `ThemeDefinition.appearance` was declared but never read, so a dark theme could be assigned to
/// the light slot and the app would honour it. Filtering the list is only half the fix: a user
/// already holding a mismatched theme would find their current row missing, so the slot has to be
/// re-anchored to the matching default in the same change.
internal enum ThemeSlotValidation {
    internal static func fits(_ appearance: ThemeAppearance, slot: ThemeAppearance) -> Bool {
        appearance == .auto || appearance == slot
    }

    internal static func eligibleThemes(
        _ themes: [ThemeDefinition],
        slot: ThemeAppearance
    ) -> [ThemeDefinition] {
        themes.filter { fits($0.appearance, slot: slot) }
    }

    /// Returns the theme id the slot should hold. An id that no longer resolves, or one whose
    /// appearance contradicts the slot, falls back to the slot's default.
    internal static func resolvedThemeId(
        current: String,
        slot: ThemeAppearance,
        themes: [ThemeDefinition],
        defaultId: String
    ) -> String {
        guard let theme = themes.first(where: { $0.id == current }) else { return defaultId }
        return fits(theme.appearance, slot: slot) ? current : defaultId
    }
}
