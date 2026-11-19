//
//  WindowMenuBuilder.swift
//  TablePro
//

import AppKit

// The window-tabbing commands live here because `NSWindow` validates them, so they dim outside a tab group.
// Owning `selectPreviousTab:` and `selectNextTab:` stops AppKit inserting its own pair, which took Control-Tab from Switch to Recent Tab.
@MainActor
enum WindowMenuBuilder {
    static let tabNumberRange = 1...9

    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        var items: [NSMenuItem] = [
            MenuItemFactory.item(
                String(localized: "Minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m",
                modifiers: .command
            ),
            MenuItemFactory.item(
                String(localized: "Zoom"),
                action: #selector(NSWindow.performZoom(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Show Previous Tab"),
                action: #selector(MainSplitViewController.selectPreviousEditorTab(_:)),
                shortcut: .showPreviousTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Next Tab"),
                action: #selector(MainSplitViewController.selectNextEditorTab(_:)),
                shortcut: .showNextTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Switch to Recent Tab"),
                action: #selector(MainSplitViewController.switchToRecentTab(_:)),
                shortcut: .switchToRecentTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Switch to Least Recent Tab"),
                action: #selector(MainSplitViewController.switchToLeastRecentTab(_:)),
                shortcut: .switchToLeastRecentTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Pin Tab"),
                action: #selector(MainSplitViewController.togglePinnedEditorTab(_:)),
                shortcut: .pinTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Rename Tab"),
                action: #selector(MainSplitViewController.renameEditorTab(_:)),
                shortcut: .renameTab,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Show Previous Window Tab"),
                action: #selector(NSWindow.selectPreviousTab(_:)),
                shortcut: .showPreviousWindowTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Next Window Tab"),
                action: #selector(NSWindow.selectNextTab(_:)),
                shortcut: .showNextWindowTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Move Tab to New Window"),
                action: #selector(NSWindow.moveTabToNewWindow(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Merge All Windows"),
                action: #selector(NSWindow.mergeAllWindows(_:))
            ),
            MenuItemFactory.separator
        ]

        items.append(contentsOf: tabNumberRange.map { number in
            MenuItemFactory.item(
                String(format: String(localized: "Select Tab %d"), number),
                action: #selector(MainSplitViewController.selectNumberedTab(_:)),
                keyEquivalent: String(number),
                modifiers: .command,
                tag: number
            )
        })

        items.append(MenuItemFactory.separator)
        items.append(
            MenuItemFactory.item(
                String(localized: "Bring All to Front"),
                action: #selector(NSApplication.arrangeInFront(_:))
            )
        )

        return MenuItemFactory.menu(String(localized: "Window"), items: items)
    }
}
