//
//  CompareEndpointMenuBuilder.swift
//  TablePro
//
//  The Source and Target toolbar popups.
//
//  An endpoint is a database, not a connection. Picking only a connection is
//  what made two databases on one server impossible to compare and left the
//  schema unset, so the menu is connection then database then schema, and the
//  deeper levels load when their submenu opens rather than on every build.
//

import AppKit
import SwiftUI

@MainActor
internal final class CompareEndpointMenuBuilder: NSObject, NSMenuDelegate {
    internal enum Side {
        case source
        case target

        internal var title: String {
            switch self {
            case .source: return String(localized: "Source")
            case .target: return String(localized: "Target")
            }
        }

        internal var caption: String {
            switch self {
            case .source: return String(localized: "Will not change")
            case .target: return String(localized: "Will be changed")
            }
        }

        internal var symbol: String {
            switch self {
            case .source: return "arrow.up.right.square"
            case .target: return "arrow.down.right.square"
            }
        }

        internal var routeToken: String {
            self == .source ? "source" : "target"
        }

        internal init?(routeToken: String) {
            switch routeToken {
            case "source": self = .source
            case "target": self = .target
            default: return nil
            }
        }
    }

    private let session: CompareSyncSession
    private let onChange: () -> Void
    private let metadata = CompareMetadataService()

    private var items: [Side: NSMenuToolbarItem] = [:]
    private var databasesByConnection: [UUID: [String]] = [:]
    private var schemasByEndpoint: [String: [String]] = [:]
    private var loading: Set<String> = []

    internal init(session: CompareSyncSession, onChange: @escaping () -> Void) {
        self.session = session
        self.onChange = onChange
        super.init()
    }

    internal func item(for side: Side, identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = side.title
        item.paletteLabel = side.title
        item.toolTip = side.caption
        item.image = NSImage(systemSymbolName: side.symbol, accessibilityDescription: side.title)
        item.showsIndicator = true
        let menu = NSMenu()
        menu.delegate = self
        menu.identifier = NSUserInterfaceItemIdentifier(side.routeToken)
        item.menu = menu
        items[side] = item
        refreshTitles()
        return item
    }

    internal func refreshTitles() {
        for (side, item) in items {
            let endpoint = side == .source ? session.source : session.target
            item.title = endpoint?.qualifiedDescription ?? String(format: chooseFormat, side.title)
        }
    }

    private var chooseFormat: String {
        String(localized: "Choose %@")
    }

    // MARK: - Menu construction

    internal func menuNeedsUpdate(_ menu: NSMenu) {
        let parts = (menu.identifier?.rawValue ?? "").split(separator: "|").map(String.init)
        guard let first = parts.first, let side = Side(routeToken: first) else { return }
        if parts.count > 1 {
            switch parts[1] {
            case "db":
                guard parts.count > 2, let connectionId = UUID(uuidString: parts[2]) else { return }
                databaseMenuNeedsUpdate(menu, side: side, connectionId: connectionId)
            case "schema":
                guard parts.count > 3, let connectionId = UUID(uuidString: parts[2]) else { return }
                schemaMenuNeedsUpdate(
                    menu, side: side, connectionId: connectionId,
                    database: parts[3...].joined(separator: "|")
                )
            default:
                return
            }
            return
        }
        menu.removeAllItems()
        let connections = ConnectionStorage.shared.loadConnections()
        guard !connections.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "No saved connections"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for connection in connections {
            menu.addItem(connectionItem(connection, side: side))
        }
    }

    private func connectionItem(_ connection: DatabaseConnection, side: Side) -> NSMenuItem {
        let item = NSMenuItem(title: connection.name, action: nil, keyEquivalent: "")
        item.image = colorSwatch(connection.color)

        if side == .target, connection.safeModeLevel == .readOnly {
            item.isEnabled = false
            item.toolTip = String(localized: "Read-Only. Choose a different connection to write changes to.")
            return item
        }

        let submenu = NSMenu()
        submenu.delegate = self
        submenu.identifier = NSUserInterfaceItemIdentifier(
            "\(side.routeToken)|db|\(connection.id.uuidString)"
        )
        item.submenu = submenu
        return item
    }

    private func databaseMenuNeedsUpdate(_ menu: NSMenu, side: Side, connectionId: UUID) {
        menu.removeAllItems()
        guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }) else {
            return
        }
        guard let databases = databasesByConnection[connectionId] else {
            menu.addItem(loadingItem())
            load(databasesFor: connection, menu: menu)
            return
        }
        guard !databases.isEmpty else {
            menu.addItem(pick(
                endpoint: CompareSyncEndpoint.from(connection: connection),
                side: side,
                title: connection.database ?? connection.name
            ))
            return
        }
        for database in databases {
            let endpoint = CompareSyncEndpoint.from(connection: connection, database: database)
            if PluginManager.shared.supportsSchemaSwitching(for: connection.type) {
                let item = NSMenuItem(title: database, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.delegate = self
                submenu.identifier = NSUserInterfaceItemIdentifier(
                    "\(side.routeToken)|schema|\(connectionId.uuidString)|\(database)"
                )
                item.submenu = submenu
                menu.addItem(item)
            } else {
                menu.addItem(pick(endpoint: endpoint, side: side, title: database))
            }
        }
    }

    private func schemaMenuNeedsUpdate(_ menu: NSMenu, side: Side, connectionId: UUID, database: String) {
        menu.removeAllItems()
        guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }) else {
            return
        }
        let base = CompareSyncEndpoint.from(connection: connection, database: database)
        menu.addItem(pick(endpoint: base, side: side, title: String(localized: "All schemas")))

        let key = "\(connectionId.uuidString)|\(database)"
        guard let schemas = schemasByEndpoint[key] else {
            menu.addItem(loadingItem())
            load(schemasFor: base, connection: connection, key: key, menu: menu)
            return
        }
        guard !schemas.isEmpty else { return }
        menu.addItem(.separator())
        for schema in schemas {
            menu.addItem(pick(endpoint: base.withSchema(schema), side: side, title: schema))
        }
    }

    private func pick(endpoint: CompareSyncEndpoint, side: Side, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CompareEndpointSelection(side: side, endpoint: endpoint)
        let current = side == .source ? session.source : session.target
        item.state = current?.id == endpoint.id ? .on : .off
        return item
    }

    private func loadingItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Loading…"), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? CompareEndpointSelection else { return }
        switch selection.side {
        case .source: session.source = selection.endpoint
        case .target: session.target = selection.endpoint
        }
        refreshTitles()
        onChange()
    }

    // MARK: - Lazy loads

    /// A menu cannot wait on a network read, so the submenu opens showing "Loading…" and is
    /// rebuilt once the answer arrives. The load is keyed so a menu opened twice does not run it
    /// twice.
    private func load(databasesFor connection: DatabaseConnection, menu: NSMenu) {
        let key = "db|\(connection.id.uuidString)"
        guard loading.insert(key).inserted else { return }
        let service = metadata
        Task { [weak self] in
            let databases = (try? await service.databases(for: connection)) ?? []
            guard let self else { return }
            self.loading.remove(key)
            self.databasesByConnection[connection.id] = databases
            menu.update()
        }
    }

    private func load(
        schemasFor endpoint: CompareSyncEndpoint,
        connection: DatabaseConnection,
        key: String,
        menu: NSMenu
    ) {
        guard loading.insert("schema|\(key)").inserted else { return }
        let service = metadata
        Task { [weak self] in
            let schemas = (try? await service.schemas(for: endpoint, connection: connection)) ?? []
            guard let self else { return }
            self.loading.remove("schema|\(key)")
            self.schemasByEndpoint[key] = schemas
            menu.update()
        }
    }

    private func colorSwatch(_ color: ConnectionColor) -> NSImage? {
        guard color != .none else { return nil }
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(color.color).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

private final class CompareEndpointSelection: NSObject {
    let side: CompareEndpointMenuBuilder.Side
    let endpoint: CompareSyncEndpoint

    init(side: CompareEndpointMenuBuilder.Side, endpoint: CompareSyncEndpoint) {
        self.side = side
        self.endpoint = endpoint
        super.init()
    }
}
