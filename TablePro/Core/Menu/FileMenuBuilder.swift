//
//  FileMenuBuilder.swift
//  TablePro
//

import AppKit

@MainActor
enum FileMenuBuilder {
    /// Retained for the menu's lifetime, which is the app's: `NSMenu.delegate` is unowned.
    private static let closeTitleDelegate = CloseCommandMenuDelegate()
    private static let importFormatDelegate = ImportFormatMenuDelegate()
    private static let agentSessionDelegate = AgentSessionMenuDelegate()
    private static let conversationHistoryDelegate = ConversationHistoryMenuDelegate()

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
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Save"),
                action: #selector(MainSplitViewController.saveDocument(_:)),
                shortcut: .saveChanges,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Save As…"),
                action: #selector(MainSplitViewController.saveDocumentAs(_:)),
                shortcut: .saveAs,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            /// `performClose:` is the close command every `NSWindow` implements and validates, so
            /// Command W reaches Settings, the integrations activity window and every viewer the
            /// app opens. An app-specific selector here reached only the editor window, and the
            /// windows that missed out had to answer it by hand. `EditorWindow` overrides it to
            /// close the front tab, which is where a window that draws its own tabs says so.
            /// Built with the title the resolver gives a window with no tabs; the File menu's
            /// delegate resolves it from the key window from then on.
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
                String(localized: "Backup Dump…"),
                action: #selector(MainSplitViewController.backupDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Restore Dump…"),
                action: #selector(MainSplitViewController.restoreDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Server-Side Export…"),
                action: #selector(MainSplitViewController.serverSideExport(_:))
            )
        ])
        file.submenu?.delegate = closeTitleDelegate
        return file
    }

    /// Agent mode's four session commands and the assistant's three conversation commands, which
    /// between them had no menu-bar home at all: the rail's buttons and the pane header's menu were
    /// the only routes, so none of them could be found by search, rebound, or reached by a user who
    /// had the rail collapsed. They sit in File because a session and a conversation are things this
    /// window opens, closes and throws away, which is what the rest of this menu is about.
    ///
    /// Each command has exactly one item here, and each item leaves `target` nil, so the window
    /// validates it through the responder chain and dims what the mode cannot run.
    private static func sessionSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Session"), items: [
            MenuItemFactory.item(
                String(localized: "New Session"),
                action: #selector(MainSplitViewController.newAgentSession(_:)),
                shortcut: .newAgentSession,
                keyboard: keyboard
            ),
            /// Opens the session the rail has highlighted, which is what Return on the rail does.
            /// A separate leaf rather than the list's own row: AppKit ignores a key equivalent on an
            /// item that owns a submenu, so making this the list would hand Settings a binding that
            /// records, reads back and never fires. That is the same trap Import Data… is split
            /// around, and it is why the list is a row of its own below.
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

    /// Every session the connection on screen owns, latest first, filled when it opens. A session
    /// list built at menu-build time would be one window's sessions frozen at launch.
    private static func recentSessionsSubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Recent Sessions"), items: [])
        container.submenu?.delegate = agentSessionDelegate
        return container
    }

    /// The assistant's stored conversations, filled when it opens for the same reason: the set
    /// changes with every reply. The pane header's own menu offers the same list, and both put the
    /// choice through the window so neither can act on a connection the other is showing.
    private static func conversationHistorySubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Conversation History"), items: [])
        container.submenu?.delegate = conversationHistoryDelegate
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

    /// Every format the connection imports from. Import Data… above it takes the first one, which
    /// left the menu bar with no route to any other: the toolbar's Import item was the only one, and
    /// a toolbar item is not a menu-bar command. The Actions pull-down offers the same list under the
    /// same title, and the two are filled by the same class when they open.
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
                action: #selector(MainSplitViewController.exportQueryResults(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Export Connections…"),
                action: #selector(AppDelegate.exportConnections(_:))
            )
        ])
    }
}
