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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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
        for schema in sections.user {
            menu.addItem(item(for: schema, current: current))
        }
        guard !sections.system.isEmpty else { return }
        menu.addItem(.separator())
        for schema in sections.system {
            menu.addItem(item(for: schema, current: current))
        }
    }

    private func item(for schema: String, current: String?) -> NSMenuItem {
        let item = NSMenuItem(title: schema, action: Self.action, keyEquivalent: "")
        item.target = nil
        item.representedObject = schema
        item.state = schema == current ? .on : .off
        return item
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
