//
//  FileMenuBuilder.swift
//  TablePro
//

import AppKit

@MainActor
enum FileMenuBuilder {
    /// Retained for the menu's lifetime, which is the app's: `NSMenu.delegate` is unowned.
    private static let closeTitleDelegate = CloseCommandMenuDelegate()

    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        let file = MenuItemFactory.menu(String(localized: "File"), items: [
            MenuItemFactory.item(
                String(localized: "New Connection..."),
                action: #selector(AppDelegate.newConnection(_:)),
                shortcut: .newConnection,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "New Tab"),
                action: #selector(MainSplitViewController.newEditorTab(_:)),
                shortcut: .newTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Manage Connections"),
                action: #selector(AppDelegate.manageConnections(_:)),
                shortcut: .manageConnections,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Open File..."),
                action: #selector(MainSplitViewController.openSQLFile(_:)),
                shortcut: .openFile,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Open Quickly..."),
                action: #selector(MainSplitViewController.openQuickSwitcher(_:)),
                shortcut: .quickSwitcher,
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
                String(localized: "Save As..."),
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
                String(localized: "Backup Dump..."),
                action: #selector(MainSplitViewController.backupDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Restore Dump..."),
                action: #selector(MainSplitViewController.restoreDatabase(_:))
            )
        ])
        file.submenu?.delegate = closeTitleDelegate
        return file
    }

    private static func importSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Import"), items: [
            MenuItemFactory.item(
                String(localized: "Import Connections..."),
                action: #selector(AppDelegate.importConnections(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import from URL..."),
                action: #selector(AppDelegate.importFromURL(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import from Other App..."),
                action: #selector(AppDelegate.importFromOtherApp(_:))
            )
        ])
        container.submenu?.insertItem(.separator(), at: 0)
        container.submenu?.insertItem(
            MenuItemFactory.item(
                String(localized: "Import Data..."),
                action: #selector(MainSplitViewController.importData(_:)),
                shortcut: .importData,
                keyboard: keyboard
            ),
            at: 0
        )
        return container
    }

    private static func exportSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Export"), items: [
            MenuItemFactory.item(
                String(localized: "Export Tables..."),
                action: #selector(MainSplitViewController.exportTables(_:)),
                shortcut: .export,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Export Results..."),
                action: #selector(MainSplitViewController.exportQueryResults(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Export Connections..."),
                action: #selector(AppDelegate.exportConnections(_:))
            )
        ])
    }
}
