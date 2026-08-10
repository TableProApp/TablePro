//
//  MenuItemFactory.swift
//  TablePro
//

import AppKit

/// Builds the menu bar's items. Every item leaves `target` nil so AppKit resolves
/// it against the key window's responder chain and asks that responder whether the
/// item is enabled, which is the only mechanism that serves both a SwiftUI scene
/// and an AppKit-owned window.
enum MenuItemFactory {
    /// Stamped onto every item that carries a customizable shortcut so
    /// `MainMenuKeyEquivalentSync` can find it again after the user rebinds.
    static func identifier(for action: ShortcutAction) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("shortcut.\(action.rawValue)")
    }

    static func item(
        _ title: String,
        action: Selector?,
        target: AnyObject? = nil,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    static func item(
        _ title: String,
        action: Selector?,
        shortcut: ShortcutAction,
        keyboard: KeyboardSettings,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = item(title, action: action, target: target, tag: tag)
        item.identifier = identifier(for: shortcut)
        apply(shortcut: shortcut, keyboard: keyboard, to: item)
        return item
    }

    static func apply(shortcut: ShortcutAction, keyboard: KeyboardSettings, to item: NSMenuItem) {
        guard let resolved = keyboard.menuKeyEquivalent(for: shortcut) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = resolved.characters
        item.keyEquivalentModifierMask = resolved.modifiers
    }

    static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let container = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items {
            menu.addItem(item)
        }
        container.submenu = menu
        return container
    }

    static func menu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        submenu(title, items: items)
    }

    static var separator: NSMenuItem {
        .separator()
    }
}
