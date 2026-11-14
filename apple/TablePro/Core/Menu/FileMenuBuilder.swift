//
//  FileMenuBuilder.swift
//  TablePro
//

import AppKit

@MainActor
enum FileMenuBuilder {
    // Retained for the app's lifetime: `NSMenu.delegate` is unowned.
    private static let closeTitleDelegate = CloseCommandMenuDelegate()
    private static let importFormatDelegate = ImportFormatMenuDelegate()
    private static let agentSessionDelegate = AgentSessionMenuDelegate()
    private static let conversationHistoryDelegate = ConversationHistoryMenuDelegate()
    private static let revertToDelegate = QueryTabRevertMenuDelegate()

    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        let file = MenuItemFactory.menu(String(localized: "File"), items: [
            MenuItemFactory.item(
                String(localized: "New Connection…"),
                action: #selector(AppDelegate.newConnection(_:)),
                shortcut: .newConnection,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "New Group…"),
                action: #selector(WelcomeWindowController.newConnectionGroup(_:))
            ),
            MenuItemFactory.item(
                String(localized: "New Tab"),
                action: #selector(MainSplitViewController.newEditorTab(_:)),
                shortcut: .newTab,
                keyboard: keyboard
            ),
            sessionSubmenu(keyboard: keyboard),
            MenuItemFactory.item(
                String(localized: "Manage Connections"),
                action: #selector(AppDelegate.manageConnections(_:)),
                shortcut: .manageConnections,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Open File…"),
                action: #selector(AppDelegate.openFile(_:)),
                shortcut: .openFile,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Open Quickly…"),
                action: #selector(MainSplitViewController.openQuickSwitcher(_:)),
                shortcut: .quickSwitcher,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Rename"),
                action: #selector(WelcomeWindowController.renameConnectionListSelection(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Copy Path"),
                action: #selector(FavoritesNSOutlineView.copyPath(_:)),
                shortcut: .copyPath,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Copy Relative Path"),
                action: #selector(FavoritesNSOutlineView.copyRelativePath(_:)),
                shortcut: .copyRelativePath,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Save"),
                action: #selector(MainSplitViewController.saveDocument(_:)),
                shortcut: .saveChanges,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Discard Changes…"),
                action: #selector(MainSplitViewController.discardChanges(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Save As…"),
                action: #selector(MainSplitViewController.saveDocumentAs(_:)),
                shortcut: .saveAs,
                keyboard: keyboard
            ),
            revertToSubmenu(),
            MenuItemFactory.separator,
            // `performClose:` reaches every window, not only the editor; `EditorWindow` overrides it to close the front tab.
            MenuItemFactory.item(
                CloseCommandTitleResolver.windowTitle,
                action: #selector(NSWindow.performClose(_:)),
                shortcut: .closeTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Close Other Tabs"),
                action: #selector(MainSplitViewController.closeOtherTabs(_:)),
                shortcut: .closeOtherTabs,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Close Tabs for Other Databases"),
                action: #selector(MainSplitViewController.closeTabsForOtherContainers(_:)),
                shortcut: .closeTabsForOtherDatabases,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Close All Tabs"),
                action: #selector(MainSplitViewController.closeAllTabs(_:)),
                shortcut: .closeAllTabs,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Close Connection"),
                action: #selector(MainSplitViewController.closeConnection(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Reopen Closed Tab"),
                action: #selector(AppDelegate.reopenClosedTab(_:)),
                shortcut: .reopenClosedTab,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            importSubmenu(keyboard: keyboard),
            exportSubmenu(keyboard: keyboard),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Share Query…"),
                action: #selector(MainSplitViewController.shareQuery(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Share Result…"),
                action: #selector(MainSplitViewController.shareQueryResult(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Manage Shared Links…"),
                action: #selector(AppDelegate.manageSharedLinks(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Backup Dump…"),
                action: #selector(MainSplitViewController.backupDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Restore Dump…"),
                action: #selector(MainSplitViewController.restoreDatabase(_:))
            )
        ])
        file.submenu?.delegate = closeTitleDelegate
        return file
    }

    // A session and a conversation are things this window opens and closes. Each item leaves `target` nil, so the
    // window validates it through the responder chain.
    private static func sessionSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Session"), items: [
            MenuItemFactory.item(
                String(localized: "New Session"),
                action: #selector(MainSplitViewController.newAgentSession(_:)),
                shortcut: .newAgentSession,
                keyboard: keyboard
            ),
            // A leaf beside the list: AppKit ignores a key equivalent on an item that owns a submenu.
            MenuItemFactory.item(
                String(localized: "Open Session"),
                action: #selector(MainSplitViewController.openAgentSession(_:)),
                shortcut: .openAgentSession,
                keyboard: keyboard
            ),
            recentSessionsSubmenu(),
            MenuItemFactory.item(
                String(localized: "Close Session"),
                action: #selector(MainSplitViewController.closeAgentSession(_:)),
                shortcut: .closeAgentSession,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Delete Session…"),
                action: #selector(MainSplitViewController.deleteAgentSession(_:)),
                shortcut: .deleteAgentSession,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "New Conversation"),
                action: #selector(MainSplitViewController.newAIConversation(_:)),
                shortcut: .newAIConversation,
                keyboard: keyboard
            ),
            conversationHistorySubmenu(),
            MenuItemFactory.item(
                String(localized: "Clear Recents…"),
                action: #selector(MainSplitViewController.clearAIConversations(_:))
            )
        ])
    }

    // Filled when it opens; a list built with the menu bar would be frozen at launch.
    private static func recentSessionsSubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Recent Sessions"), items: [])
        container.submenu?.delegate = agentSessionDelegate
        return container
    }

    // Filled when it opens, since the set changes with every reply.
    private static func conversationHistorySubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Conversation History"), items: [])
        container.submenu?.delegate = conversationHistoryDelegate
        return container
    }

    // The selected query tab's recent versions, filled when it opens. No shortcut: AppKit ignores one on this row.
    private static func revertToSubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Revert To"), items: [])
        container.submenu?.delegate = revertToDelegate
        return container
    }

    private static func importSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Import"), items: [
            MenuItemFactory.item(
                String(localized: "Import Connections…"),
                action: #selector(AppDelegate.importConnections(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import from URL…"),
                action: #selector(AppDelegate.importFromURL(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import from Other App…"),
                action: #selector(AppDelegate.importFromOtherApp(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import from AWS…"),
                action: #selector(AppDelegate.importFromAWS(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Open Project Folder…"),
                action: #selector(AppDelegate.openProjectFolder(_:))
            )
        ])
        container.submenu?.insertItem(.separator(), at: 0)
        container.submenu?.insertItem(importFormatsSubmenu(), at: 0)
        container.submenu?.insertItem(
            MenuItemFactory.item(
                String(localized: "Import Data…"),
                action: #selector(MainSplitViewController.importData(_:)),
                shortcut: .importData,
                keyboard: keyboard
            ),
            at: 0
        )
        return container
    }

    // For a format the file's extension does not name; the Actions pull-down fills the same list with the same class.
    private static func importFormatsSubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Import Data From"), items: [])
        container.submenu?.delegate = importFormatDelegate
        return container
    }

    private static func exportSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Export"), items: [
            MenuItemFactory.item(
                String(localized: "Export Tables…"),
                action: #selector(MainSplitViewController.exportTables(_:)),
                shortcut: .export,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Export Results…"),
                action: #selector(MainSplitViewController.exportQueryResults(_:)),
                shortcut: .exportResults,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Export Data Dictionary…"),
                action: #selector(MainSplitViewController.exportDataDictionary(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Export Connections…"),
                action: #selector(AppDelegate.exportConnections(_:))
            )
        ])
    }
}
