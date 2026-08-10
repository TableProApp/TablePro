//
//  WindowMenuBuilder.swift
//  TablePro
//

import AppKit

/// AppKit appends the open-window list and the native tab items (Show Tab Bar,
/// Show All Tabs, Merge All Windows) to whichever menu is assigned to
/// `NSApp.windowsMenu`, so only the items it does not provide are built here.
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
                action: #selector(NSWindow.selectPreviousTab(_:)),
                shortcut: .showPreviousTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Next Tab"),
                action: #selector(NSWindow.selectNextTab(_:)),
                shortcut: .showNextTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Move Tab to New Window"),
                action: #selector(NSWindow.moveTabToNewWindow(_:))
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
