//
//  EditorTabContextMenuBuilder.swift
//  TablePro
//

import AppKit

@MainActor
internal enum EditorTabContextMenuBuilder {
    private struct Command {
        let title: String
        var isEnabled = true
        var startsGroup = false
        let action: () -> Void
    }

    internal static func menu(for tabId: UUID, commands: EditorTabCommands) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in entries(for: tabId, commands: commands) {
            if command.startsGroup {
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuTarget.item(
                title: command.title,
                isEnabled: command.isEnabled,
                action: command.action
            ))
        }
        return menu
    }

    // The rotor lists only what would do something, the same commands the menu offers.
    internal static func accessibilityActions(
        for tabId: UUID,
        commands: EditorTabCommands
    ) -> [NSAccessibilityCustomAction] {
        entries(for: tabId, commands: commands).filter(\.isEnabled).map { command in
            let action = command.action
            return NSAccessibilityCustomAction(name: command.title) {
                action()
                return true
            }
        }
    }

    internal static func pinTitle(isPinned: Bool) -> String {
        isPinned ? String(localized: "Unpin Tab") : String(localized: "Pin Tab")
    }

    private static func entries(for tabId: UUID, commands: EditorTabCommands) -> [Command] {
        let isPinned = commands.isPinned(tabId)
        var entries = [
            Command(title: String(localized: "Keep Open"), isEnabled: commands.canKeepOpen(tabId)) {
                commands.keepOpen(tabId)
            },
            Command(title: pinTitle(isPinned: isPinned)) { commands.setPinned(tabId, !isPinned) },
        ]
        // Hidden rather than dimmed on a tab that can never take a name, as the HIG asks of context menus.
        if commands.canRename(tabId) {
            entries.append(Command(title: String(localized: "Rename Tab")) { commands.beginRename(tabId) })
        }
        entries += [
            Command(title: String(localized: "Close Tab"), startsGroup: true) { commands.close(tabId) },
            Command(title: String(localized: "Close Other Tabs"), isEnabled: commands.canCloseOthers(tabId)) {
                commands.closeOthers(tabId)
            },
            Command(title: String(localized: "Close All Tabs"), isEnabled: commands.canCloseAll()) {
                commands.closeAll()
            },
            Command(
                title: String(localized: "Move Tab Left"),
                isEnabled: commands.canMove(tabId, -1),
                startsGroup: true
            ) { commands.moveBy(tabId, -1) },
            Command(title: String(localized: "Move Tab Right"), isEnabled: commands.canMove(tabId, 1)) {
                commands.moveBy(tabId, 1)
            },
            Command(
                title: String(localized: "Move Tab to New Window"),
                isEnabled: commands.canTearOff(tabId),
                startsGroup: true
            ) { commands.tearOff(tabId, nil) },
        ]
        // Hidden rather than dimmed on a tab that can never move, as the HIG asks of context menus.
        if commands.offersMoveToConnection(tabId) {
            entries.append(Command(
                title: String(localized: "Move Tab to Connection…"),
                isEnabled: commands.canMoveToConnection(tabId)
            ) { commands.moveToConnection(tabId) })
        }
        return entries
    }
}
