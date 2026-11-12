//
//  DatabaseTreeConnectionRows.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit

/// A saved connection's row in the database tree. The tree's own connection holds everything the
/// tree lists without connections; every other one is a row to switch to or open.
internal struct DatabaseTreeSavedConnectionRef: Equatable {
    internal let row: ConnectionNavigatorConnectionRow
    internal let ownsTree: Bool

    internal var id: UUID { row.id }
}

/// What a double click or Return on a saved connection's row does.
internal enum DatabaseTreeConnectionActivation: Equatable {
    case toggleDisclosure
    case switchTo(UUID)
    case open(UUID)
}

/// The saved connections the database tree lists above its own connection's databases, so the
/// sidebar reads as one tree: group, connection, database, objects.
///
/// Each workspace owns its sidebar, so each tree lists the same connections and opens only its own.
/// The rows come from the navigator's builder, so the tree and the connections column agree on
/// grouping and order.
internal enum DatabaseTreeConnectionRows {
    /// Only the database tree has a level above its containers for a connection to sit at. The flat
    /// list and the schema list are one container's objects.
    internal static func applies(settingEnabled: Bool, rootShape: SidebarRootShape) -> Bool {
        settingEnabled && rootShape == .databaseTree
    }

    @MainActor
    internal static func applies(settingEnabled: Bool, databaseType: DatabaseType, layout: SidebarLayout) -> Bool {
        guard settingEnabled else { return false }
        let plugins = PluginManager.shared
        return applies(
            settingEnabled: settingEnabled,
            rootShape: SidebarRootShapeResolver.resolve(
                groupingStrategy: plugins.databaseGroupingStrategy(for: databaseType),
                sidebarLayout: layout,
                supportsDatabaseTree: plugins.supportsDatabaseTree(for: databaseType)
            )
        )
    }

    /// The rows the tree lists at its top.
    ///
    /// The sidebar filter searches the tree's objects, so the tree's own connection always stays, with
    /// the groups above it: hiding it would hide every object the filter found. Any other connection
    /// stays while its name matches. A connection the library does not hold, one opened from a file
    /// or a link, is listed first, so its databases still have a row to hang from.
    nonisolated internal static func rows(
        from library: [ConnectionNavigatorRow],
        ownId: UUID,
        unsavedOwnRow: ConnectionNavigatorConnectionRow? = nil,
        filterText: String
    ) -> [ConnectionNavigatorRow] {
        let term = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = term.isEmpty ? library : filtered(library, term: term, keeping: ownId)
        if let unsavedOwnRow, unsavedOwnRow.id == ownId, !contains(ownId, in: library) {
            rows.insert(.connection(unsavedOwnRow), at: 0)
        }
        return rows
    }

    /// While the filter runs every group it leaves is open, since each one holds a match or the
    /// tree's own connection. The user's own choice comes back with the filter cleared.
    nonisolated private static func filtered(
        _ rows: [ConnectionNavigatorRow],
        term: String,
        keeping ownId: UUID?
    ) -> [ConnectionNavigatorRow] {
        rows.compactMap { row -> ConnectionNavigatorRow? in
            switch row {
            case .connection(let connection):
                let keeps = connection.id == ownId || connection.connection.name.localizedCaseInsensitiveContains(term)
                return keeps ? row : nil
            case .group(let group):
                let children = filtered(group.children, term: term, keeping: ownId)
                guard !children.isEmpty else { return nil }
                return .group(ConnectionNavigatorGroupRow(
                    id: group.id,
                    name: group.name,
                    color: group.color,
                    iconName: group.iconName,
                    connectionCount: connectionCount(in: children),
                    isExpanded: true,
                    children: children
                ))
            }
        }
    }

    nonisolated private static func connectionCount(in rows: [ConnectionNavigatorRow]) -> Int {
        rows.reduce(0) { count, row in
            switch row {
            case .connection: return count + 1
            case .group(let group): return count + connectionCount(in: group.children)
            }
        }
    }

    nonisolated internal static func contains(_ connectionId: UUID, in rows: [ConnectionNavigatorRow]) -> Bool {
        groupIds(above: connectionId, in: rows) != nil
    }

    /// The groups holding a connection, outermost first, or nil when the rows do not hold it.
    nonisolated internal static func groupIds(above connectionId: UUID, in rows: [ConnectionNavigatorRow]) -> [UUID]? {
        for row in rows {
            switch row {
            case .connection(let connection):
                if connection.id == connectionId { return [] }
            case .group(let group):
                if let inner = groupIds(above: connectionId, in: group.children) {
                    return [group.id] + inner
                }
            }
        }
        return nil
    }

    /// The tree's own row discloses its databases. Another connection this window hosts is a
    /// switch; one it does not host opens through the router, which raises a window already showing
    /// it and otherwise opens it here.
    nonisolated internal static func activation(
        of ref: DatabaseTreeSavedConnectionRef,
        hostedHere: Set<UUID>
    ) -> DatabaseTreeConnectionActivation {
        if ref.ownsTree { return .toggleDisclosure }
        return hostedHere.contains(ref.id) ? .switchTo(ref.id) : .open(ref.id)
    }

    /// A click that lands on another connection this window hosts switches to it, as a click in the
    /// connections column does. Only a click: arrowing down the tree must not hop between workspaces
    /// row by row, and a click on a connection nobody hosts never dials one by accident.
    nonisolated internal static func clickSwitchTarget(
        selected kinds: [DatabaseTreeNode.Kind],
        hostedHere: Set<UUID>,
        isPointerClick: Bool
    ) -> UUID? {
        guard isPointerClick, kinds.count == 1, case .savedConnection(let ref) = kinds[0],
              !ref.ownsTree, hostedHere.contains(ref.id)
        else { return nil }
        return ref.id
    }
}
