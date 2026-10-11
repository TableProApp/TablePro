//
//  WindowMenuBuilder.swift
//  TablePro
//

import AppKit

/// AppKit appends the open-window list to whichever menu is assigned to `NSApp.windowsMenu`. The
/// window-tabbing commands are built here because the app opts into window tabbing through
/// `NSWindow.tabbingMode`, and `NSWindow` implements and validates all four, so they dim when the
/// window is not part of a tab group.
///
/// The two that switch window tabs have to be built here too, under their own names. When a menu
/// does not already hold `selectPreviousTab:` and `selectNextTab:`, AppKit inserts its own the first
/// time the menu is shown, titled Show Previous Tab and Show Next Tab and bound to Control-Shift-Tab
/// and Control-Tab. Measured: that put a second pair with the editor tabs' titles in this menu, and
/// once inserted it took Control-Tab ahead of Switch to Recent Tab and switched the window tab
/// instead. Owning both actions stops the insertion, and leaves View's Show Tab Bar and Show All
/// Tabs in place. The names are Xcode's, which has both kinds of tab as well.
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
