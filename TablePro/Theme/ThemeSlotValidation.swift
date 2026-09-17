//
//  ThemeSlotValidation.swift
//  TablePro
//

import Foundation

/// `ThemeDefinition.appearance` was declared but never read, so a dark theme could be assigned to
/// the light slot and the app would honour it. The list is filtered to the themes that suit the
/// slot, and the theme the slot already holds is always kept in it.
///
/// Rewriting the saved id to make the filter true is not an option: a settings pane is a
/// presentation surface, and the rewrite fired on appear, so opening Appearance silently replaced
/// a theme the user had chosen and then hid it from the list they would have used to put it back.
internal enum ThemeSlotValidation {
    internal static func fits(_ appearance: ThemeAppearance, slot: ThemeAppearance) -> Bool {
        appearance == .auto || appearance == slot
    }

    internal static func eligibleThemes(
        _ themes: [ThemeDefinition],
        slot: ThemeAppearance,
        keeping selectedId: String?
    ) -> [ThemeDefinition] {
        themes.filter { fits($0.appearance, slot: slot) || $0.id == selectedId }
    }
}
