//
//  WindowMenuBuilder.swift
//  TablePro
//

import AppKit

/// AppKit appends the open-window list to whichever menu is assigned to `NSApp.windowsMenu`, and
/// that is all it appends. It does not contribute the window-tabbing commands: a menu built in code
/// gets the window list and nothing else, measured with two windows actually in one tab group. The
/// app still opts into window tabbing through `NSWindow.tabbingMode`, so the commands that go with
/// it are built here. `NSWindow` implements both and validates them itself, so they dim when the
/// window is not part of a tab group.
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
