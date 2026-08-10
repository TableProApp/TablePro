//
//  MainMenuKeyEquivalentSync.swift
//  TablePro
//

import AppKit

/// Re-applies customized shortcuts onto an already-built menu bar, so rebinding in
/// Settings reaches the menu without rebuilding it.
///
/// A grid action whose binding shadows a standard text-editing key has to drop its
/// key equivalent, not merely disable its item: AppKit matches a menu key equivalent
/// before the keystroke reaches the first responder and swallows the event even when
/// the item is disabled, which would strand the focused text field.
enum MainMenuKeyEquivalentSync {
    static func apply(keyboard: KeyboardSettings, to menu: NSMenu) {
        forEachShortcutItem(in: menu) { item, action in
            MenuItemFactory.apply(shortcut: action, keyboard: keyboard, to: item)
        }
    }

    static func applyTextInputYield(
        keyboard: KeyboardSettings,
        yields: (ShortcutAction, BoundKey) -> Bool,
        to menu: NSMenu
    ) {
        forEachShortcutItem(in: menu) { item, action in
            guard let key = keyboard.shortcut(for: action), yields(action, key) else {
                MenuItemFactory.apply(shortcut: action, keyboard: keyboard, to: item)
                return
            }
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private static func forEachShortcutItem(in menu: NSMenu, body: (NSMenuItem, ShortcutAction) -> Void) {
        for item in menu.items {
            if let submenu = item.submenu {
                forEachShortcutItem(in: submenu, body: body)
            }
            guard let action = shortcutAction(for: item) else { continue }
            body(item, action)
        }
    }

    private static func shortcutAction(for item: NSMenuItem) -> ShortcutAction? {
        guard let raw = item.identifier?.rawValue, raw.hasPrefix("shortcut.") else { return nil }
        return ShortcutAction(rawValue: String(raw.dropFirst("shortcut.".count)))
    }
}
