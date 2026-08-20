//
//  DatabaseMenuBuilder.swift
//  TablePro
//

import AppKit

/// "Open Database" and "Close Tabs for Other Databases" read Database or Schema
/// depending on what the driver switches between. That is a closed two-string set
/// driven by `ContainerSwitchTarget`, not an interpolated driver name, because
/// System Settings binds an App Shortcut to a menu item's exact literal title.
@MainActor
enum DatabaseMenuBuilder {
    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.menu(String(localized: "Database"), items: [
            MenuItemFactory.item(
                String(localized: "Switch Connection..."),
                action: #selector(MainSplitViewController.switchConnection(_:)),
                shortcut: .switchConnection,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Open Database..."),
                action: #selector(MainSplitViewController.openContainerSwitcher(_:)),
                shortcut: .openDatabase,
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
                String(localized: "New Database..."),
                action: #selector(MainSplitViewController.createNewDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "New Table..."),
                action: #selector(MainSplitViewController.createNewTable(_:))
            ),
            MenuItemFactory.item(
                String(localized: "New View..."),
                action: #selector(MainSplitViewController.createNewView(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Show Table Structure"),
                action: #selector(MainSplitViewController.showTableStructure(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Edit View Definition..."),
                action: #selector(MainSplitViewController.editViewDefinition(_:))
            ),
            schemaSubmenu(),
            maintenanceSubmenu(),
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
            ),
            MenuItemFactory.item(
                String(localized: "Query Insights"),
                action: #selector(MainSplitViewController.showQueryInsights(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Disconnect"),
                action: #selector(MainSplitViewController.requestDisconnect)
            ),
            MenuItemFactory.item(
                String(localized: "Reconnect"),
                action: #selector(MainSplitViewController.retryConnection)
            )
        ])
    }

    private static let maintenanceDelegate = MaintenanceMenuDelegate()

    private static func maintenanceSubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Table Maintenance"), items: [])
        container.submenu?.delegate = maintenanceDelegate
        return container
    }

    private static let schemaDelegate = SchemaMenuDelegate()

    /// Where switching schema lives now that the sidebar has no bottom bar. The active schema is
    /// still readable at a glance from the toolbar's chip, which already shows it.
    private static func schemaSubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Schema"), items: [])
        container.submenu?.delegate = schemaDelegate
        return container
    }
}
