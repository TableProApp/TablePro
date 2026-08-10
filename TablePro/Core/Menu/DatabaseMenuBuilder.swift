//
//  DatabaseMenuBuilder.swift
//  TablePro
//

import AppKit

/// "Open Database" and "Close Tabs for Other Databases" read Database or Schema
/// depending on what the driver switches between. That is a closed two-string set
/// driven by `ContainerSwitchTarget`, not an interpolated driver name, because
/// System Settings binds an App Shortcut to a menu item's exact literal title.
enum DatabaseMenuBuilder {
    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.menu(String(localized: "Database"), items: [
            MenuItemFactory.item(
                String(localized: "Switch Connection\u{2026}"),
                action: #selector(MainSplitViewController.switchConnection(_:)),
                shortcut: .switchConnection,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Open Database\u{2026}"),
                action: #selector(MainSplitViewController.openContainerSwitcher(_:)),
                shortcut: .openDatabase,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Quick Switcher\u{2026}"),
                action: #selector(MainSplitViewController.openQuickSwitcher(_:)),
                shortcut: .quickSwitcher,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Refresh"),
                action: #selector(MainSplitViewController.refreshDatabase(_:)),
                shortcut: .refresh,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "New Table\u{2026}"),
                action: #selector(MainSplitViewController.createNewTable(_:))
            ),
            MenuItemFactory.item(
                String(localized: "New View\u{2026}"),
                action: #selector(MainSplitViewController.createNewView(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Truncate Table"),
                action: #selector(MainSplitViewController.truncateTable(_:)),
                shortcut: .truncateTable,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "View ER Diagram"),
                action: #selector(MainSplitViewController.showERDiagram(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Server Dashboard"),
                action: #selector(MainSplitViewController.showServerDashboard(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Users & Roles"),
                action: #selector(MainSplitViewController.showUsersAndRoles(_:))
            )
        ])
    }
}
