//
//  ConnectionNavigatorRowsBuilder.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

/// Everything a navigator row depends on, read once by the model so the build itself touches no
/// session, window or plugin state.
internal struct ConnectionNavigatorRowsInput {
    internal var connections: [DatabaseConnection]
    internal var groups: [ConnectionGroup]
    internal var sortMode: LibrarySortMode = .manual
    internal var lastConnected: [UUID: Date] = [:]
    internal var filterText = ""
    internal var expandedGroupIds: Set<UUID> = []
    internal var statuses: [UUID: ConnectionDisplayStatus] = [:]
    internal var placements: [UUID: ConnectionNavigatorPlacement] = [:]
    internal var driverRejectedIds: Set<UUID> = []
}

/// The Welcome window's outline, cut down to the Connections section: grouping, sorting and the
/// filter come from `LibraryOutlineBuilder`, so both lists agree on where a connection sits.
internal enum ConnectionNavigatorRowsBuilder {
    nonisolated internal static func build(_ input: ConnectionNavigatorRowsInput) -> [ConnectionNavigatorRow] {
        let request = LibraryOutlineRequest(
            connections: input.connections,
            groups: input.groups,
            tags: [ConnectionTag](),
            sortMode: input.sortMode,
            query: LibraryQuery(text: input.filterText),
            lastConnected: input.lastConnected,
            includesFavorites: false,
            includesRecent: false
        )
        let outline = LibraryOutlineBuilder.build(request)
        guard let nodes = outline.section(.connections)?.nodes else { return [] }

        let graph = LibraryGroupGraph(groups: input.groups)
        let connectionsById = Dictionary(input.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupsById = Dictionary(input.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        /// While a filter runs, the groups it opened are the ones that hold a match; the user's own
        /// choice comes back with the filter cleared, because nothing here overwrote it.
        let expanded = outline.isQueryActive ? outline.groupIdsExpandedByQuery : input.expandedGroupIds

        func row(for node: LibraryNode) -> ConnectionNavigatorRow? {
            switch node {
            case .group(let id, let children, let count):
                guard let group = groupsById[id] else { return nil }
                return .group(ConnectionNavigatorGroupRow(
                    id: id,
                    name: group.name,
                    color: group.color,
                    iconName: group.iconName,
                    connectionCount: count,
                    isExpanded: expanded.contains(id),
                    children: children.compactMap(row(for:))
                ))
            case .connection(let id):
                guard let connection = connectionsById[id] else { return nil }
                let groupPath = connection.groupId.flatMap { graph.contains($0) ? graph.pathNames(to: $0) : nil } ?? []
                return .connection(ConnectionNavigatorConnectionRow(
                    connection: connection,
                    groupPath: groupPath,
                    isDriverRejected: input.driverRejectedIds.contains(id),
                    status: input.statuses[id] ?? .notConnected,
                    placement: input.placements[id] ?? .notOpen
                ))
            }
        }
        return nodes.compactMap(row(for:))
    }

    /// A status or a window moved, which changes how a row is marked and never which rows exist.
    nonisolated internal static func applying(
        statuses: [UUID: ConnectionDisplayStatus],
        placements: [UUID: ConnectionNavigatorPlacement],
        to rows: [ConnectionNavigatorRow]
    ) -> [ConnectionNavigatorRow] {
        rows.map { row in
            switch row {
            case .group(let group):
                return .group(ConnectionNavigatorGroupRow(
                    id: group.id,
                    name: group.name,
                    color: group.color,
                    iconName: group.iconName,
                    connectionCount: group.connectionCount,
                    isExpanded: group.isExpanded,
                    children: applying(statuses: statuses, placements: placements, to: group.children)
                ))
            case .connection(var connection):
                connection.status = statuses[connection.id] ?? .notConnected
                connection.placement = placements[connection.id] ?? .notOpen
                return .connection(connection)
            }
        }
    }

    /// A connection hosted both here and by a window a tab was torn off into is this window's: a
    /// click here switches to it, which is the answer that does not leave the window.
    nonisolated internal static func placement(
        of id: UUID,
        shown: UUID?,
        hostedHere: Set<UUID>,
        hostedAnywhere: Set<UUID>
    ) -> ConnectionNavigatorPlacement {
        if id == shown { return .shownHere }
        if hostedHere.contains(id) { return .openHere }
        if hostedAnywhere.contains(id) { return .openElsewhere }
        return .notOpen
    }
}
