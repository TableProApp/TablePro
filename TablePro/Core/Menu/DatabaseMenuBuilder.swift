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
                String(localized: "Switch Connection…"),
                action: #selector(MainSplitViewController.switchConnection(_:)),
                shortcut: .switchConnection,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Open Database…"),
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
                String(localized: "New Database…"),
                action: #selector(MainSplitViewController.createNewDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "New Table…"),
                action: #selector(MainSplitViewController.createNewTable(_:))
            ),
            MenuItemFactory.item(
                String(localized: "New View…"),
                action: #selector(MainSplitViewController.createNewView(_:))
            ),
            MenuItemFactory.separator,
            /// The sidebar's own Copy To and Duplicate Database, mirrored so both are reachable
            /// from the keyboard. The menu acts on the database being browsed, which is what a
            /// command with no clicked row can mean. Spelled exactly as the sidebar and the sheet
            /// spell it: one command carrying two names reads as two commands.
            MenuItemFactory.item(
                String(localized: "Copy To…"),
                action: #selector(MainSplitViewController.copyObjectsToDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Duplicate Database…"),
                action: #selector(MainSplitViewController.duplicateCurrentDatabase(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Show Table Structure"),
                action: #selector(MainSplitViewController.showTableStructure(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Edit View Definition…"),
                action: #selector(MainSplitViewController.editViewDefinition(_:))
            ),
            schemaSubmenu(),
            favoriteDatabaseSubmenu(),
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
            ),
            MenuItemFactory.separator,
            compareSubmenu()
        ])
    }

    /// The HIG asks that every toolbar item also be a menu-bar command. These are the Compare &
    /// Sync window's toolbar, mirrored here; they route by nil target, so they reach
    /// `CompareSyncWindowController` only while that window is key and validate to disabled
    /// everywhere else.
    private static func compareSubmenu() -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Compare"), items: [
            MenuItemFactory.item(
                String(localized: "Compare & Sync Databases…"),
                action: #selector(AppDelegate.compareAndSyncDatabases(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Save Comparison…"),
                action: #selector(CompareSyncWindowController.saveComparison(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Compare Now"),
                action: #selector(CompareSyncWindowController.runComparison(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Swap Source and Target"),
                action: #selector(CompareSyncWindowController.swapEndpoints(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Comparison Options…"),
                action: #selector(CompareSyncWindowController.showOptions(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Generate Script"),
                action: #selector(CompareSyncWindowController.generateScript(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Apply to Target…"),
                action: #selector(CompareSyncWindowController.applyToTarget(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Stop Comparison"),
                action: #selector(CompareSyncWindowController.stopComparison(_:))
            )
        ])
    }

    private static let favoriteDatabaseDelegate = FavoriteDatabaseMenuDelegate()

    /// A literal title, like every other item here: System Settings binds an App Shortcut to a menu
    /// item's exact title, so a title that flipped between "Add" and "Remove" would break the bind.
    /// The submenu reports the current state with a checkmark instead.
    private static func favoriteDatabaseSubmenu() -> NSMenuItem {
        let container = MenuItemFactory.submenu(String(localized: "Favorite Database"), items: [])
        container.submenu?.delegate = favoriteDatabaseDelegate
        return container
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
