//
//  FileMenuBuilder.swift
//  TablePro
//

import AppKit

enum FileMenuBuilder {
    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.menu(String(localized: "File"), items: [
            MenuItemFactory.item(
                String(localized: "New Connection\u{2026}"),
                action: #selector(AppDelegate.newConnection(_:)),
                shortcut: .newConnection,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "New Tab"),
                action: #selector(NSWindow.newWindowForTab(_:)),
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
                String(localized: "Open File\u{2026}"),
                action: #selector(MainSplitViewController.openSQLFile(_:)),
                shortcut: .openFile,
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
                String(localized: "Save As\u{2026}"),
                action: #selector(MainSplitViewController.saveDocumentAs(_:)),
                shortcut: .saveAs,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Close Tab"),
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
                String(localized: "Backup Dump\u{2026}"),
                action: #selector(MainSplitViewController.backupDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Restore Dump\u{2026}"),
                action: #selector(MainSplitViewController.restoreDatabase(_:))
            )
        ])
    }

    private static func importSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Import"), items: [
            MenuItemFactory.item(
                String(localized: "Import Connections\u{2026}"),
                action: #selector(AppDelegate.importConnections(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import from URL\u{2026}"),
                action: #selector(AppDelegate.importFromURL(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import from Other App\u{2026}"),
                action: #selector(AppDelegate.importFromOtherApp(_:))
            )
        ])
        container.submenu?.insertItem(.separator(), at: 0)
        container.submenu?.insertItem(
            MenuItemFactory.item(
                String(localized: "Import Data\u{2026}"),
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
                String(localized: "Export Tables\u{2026}"),
                action: #selector(MainSplitViewController.exportTables(_:)),
                shortcut: .export,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Export Results\u{2026}"),
                action: #selector(MainSplitViewController.exportQueryResults(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Export Connections\u{2026}"),
                action: #selector(AppDelegate.exportConnections(_:))
            )
        ])
    }
}
