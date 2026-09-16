//
//  SchemaMenuDelegate.swift
//  TablePro
//

import AppKit

/// Which schemas exist depends on the live connection, so the submenu is filled when it opens.
/// Built on the same shape as `MaintenanceMenuDelegate`, including the responder-chain lookup that
/// resolves the same window the chosen item will act on.
@MainActor
final class SchemaMenuDelegate: NSObject, NSMenuDelegate {
    private static let action = #selector(MainSplitViewController.switchToSchema(_:))

    private static let switcherAction = #selector(MainSplitViewController.openSchemaSwitcher(_:))

    private static let createAction = #selector(MainSplitViewController.createSchema(_:))

    private static let editAction = #selector(MainSplitViewController.editCurrentSchema(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        /// Added here rather than when the container was built, because this method clears the
        /// menu on every open: a statically added item is destroyed the first time the submenu is
        /// used, which reads as a command that does not exist.
        addSwitcherItem(to: menu)
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        guard let coordinator = controller?.commandActions?.coordinator else {
            addPlaceholder(to: menu)
            return
        }
        let connectionId = coordinator.connection.id
        let sections = SchemaMenuModel.sections(
            all: SchemaService.shared.schemas(for: connectionId),
            system: Set(PluginManager.shared.systemSchemaNames(for: coordinator.connection.type))
        )
        guard !sections.isEmpty else {
            addPlaceholder(to: menu)
            return
        }
        let current = DatabaseManager.shared.session(for: connectionId)?.browseSchema
        addManagementItems(to: menu, coordinator: coordinator, current: current)
        for schema in sections.user {
            menu.addItem(item(for: schema, current: current))
        }
        guard !sections.system.isEmpty else { return }
        menu.addItem(.separator())
        for schema in sections.system {
            menu.addItem(item(for: schema, current: current))
        }
    }

    /// The only route to creating and editing a schema on a sidebar shape that draws no schema
    /// row, which is every shape but the database tree. Both open a sheet, so both take an
    /// ellipsis; the noun is the engine's, so this reads "New Dataset\u{2026}" on BigQuery.
    private func addManagementItems(
        to menu: NSMenu,
        coordinator: MainContentCoordinator,
        current: String?
    ) {
        let context = coordinator.schemaEditContext
        let entity = PluginManager.shared.schemaEntityName(for: coordinator.connection.type)
        var added = false
        if SchemaEditEligibility.canCreate(context: context) {
            let item = NSMenuItem(
                title: String(format: String(localized: "New %@\u{2026}"), entity),
                action: Self.createAction,
                keyEquivalent: ""
            )
            item.target = nil
            menu.addItem(item)
            added = true
        }
        if let current, !current.isEmpty, SchemaEditEligibility.hasEditableFacet(context), !context.isReadOnly {
            let item = NSMenuItem(
                title: String(format: String(localized: "Edit %1$@ \"%2$@\"\u{2026}"), entity, current),
                action: Self.editAction,
                keyEquivalent: ""
            )
            item.target = nil
            menu.addItem(item)
            added = true
        }
        guard added else { return }
        menu.addItem(.separator())
    }

    private func item(for schema: String, current: String?) -> NSMenuItem {
        let item = NSMenuItem(title: schema, action: Self.action, keyEquivalent: "")
        item.target = nil
        item.representedObject = schema
        item.state = schema == current ? .on : .off
        return item
    }

    /// The full chooser for the inner scope. The checked list below it is the quick path; only the
    /// chooser searches, favourites, drops and exports.
    private func addSwitcherItem(to menu: NSMenu) {
        let item = NSMenuItem(
            title: String(localized: "Open Schema Switcher…"),
            action: Self.switcherAction,
            keyEquivalent: ""
        )
        item.target = nil
        menu.addItem(item)
        menu.addItem(.separator())
    }

    private func addPlaceholder(to menu: NSMenu) {
        let empty = NSMenuItem(title: String(localized: "No Schemas Available"), action: nil, keyEquivalent: "")
        empty.isEnabled = false
        menu.addItem(empty)
    }

    /// Keeps AppKit's key-equivalent search from rebuilding the menu on every modified keystroke,
    /// which would query the schema list for items that carry no key equivalent.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
