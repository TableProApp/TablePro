//
//  EditorTabContextMenuBuilder.swift
//  TablePro
//

import AppKit

/// The tab's contextual menu, built in AppKit because AppKit now owns the press.
///
/// The strip keeps its SwiftUI `.contextMenu` as well, and the two never both fire: a right-click
/// resolves through `NSView.menu(for:)` on the view that owns the press, and the SwiftUI menu is
/// left as the route VoiceOver and Full Keyboard Access already take to the same commands.
@MainActor
internal enum EditorTabContextMenuBuilder {
    internal static func menu(for tabId: UUID, commands: EditorTabCommands) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        append(
            menu,
            title: String(localized: "Keep Open"),
            isEnabled: commands.canKeepOpen(tabId)
        ) { commands.keepOpen(tabId) }

        menu.addItem(.separator())

        append(menu, title: String(localized: "Close Tab")) { commands.close(tabId) }
        append(menu, title: String(localized: "Close Other Tabs")) { commands.closeOthers(tabId) }
        append(menu, title: String(localized: "Close All Tabs")) { commands.closeAll() }

        menu.addItem(.separator())

        append(
            menu,
            title: String(localized: "Move Tab Left"),
            isEnabled: commands.canMove(tabId, -1)
        ) { commands.moveBy(tabId, -1) }
        append(
            menu,
            title: String(localized: "Move Tab Right"),
            isEnabled: commands.canMove(tabId, 1)
        ) { commands.moveBy(tabId, 1) }

        menu.addItem(.separator())

        append(
            menu,
            title: String(localized: "Move Tab to New Window"),
            isEnabled: commands.canTearOff(tabId)
        ) { commands.tearOff(tabId) }

        return menu
    }

    private static func append(
        _ menu: NSMenu,
        title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        menu.addItem(ClosureMenuTarget.item(title: title, isEnabled: isEnabled, action: action))
    }
}
