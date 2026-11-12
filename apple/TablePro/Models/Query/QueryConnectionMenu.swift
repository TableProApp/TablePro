//
//  QueryConnectionMenu.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

/// A row of the two-row query bar's connection menu: a saved connection, or a group of them.
internal enum QueryConnectionMenuItem: Identifiable, Equatable {
    case group(id: UUID, name: String, children: [QueryConnectionMenuItem])
    case connection(id: UUID, name: String, color: ConnectionColor)

    internal var id: ConnectionNavigatorRowID {
        switch self {
        case .group(let id, _, _): return .group(id)
        case .connection(let id, _, _): return .connection(id)
        }
    }
}

/// The saved connections the menu lists, in the groups and order the sidebar's connection list
/// uses, since both come from `ConnectionNavigatorRowsBuilder`.
internal enum QueryConnectionMenu {
    /// A group holding no connection is left out: a submenu that opens on nothing is a dead end.
    internal static func items(from rows: [ConnectionNavigatorRow]) -> [QueryConnectionMenuItem] {
        rows.compactMap { row in
            switch row {
            case .group(let group):
                let children = items(from: group.children)
                guard !children.isEmpty else { return nil }
                return .group(id: group.id, name: group.name, children: children)
            case .connection(let row):
                return .connection(id: row.id, name: row.connection.name, color: row.connection.color)
            }
        }
    }

    @MainActor
    internal static func load(
        connectionStorage: ConnectionStorage = .shared,
        groupStorage: GroupStorage = .shared,
        listPreferences: ConnectionListPreferences = .shared,
        recentConnections: RecentConnectionsStore = .shared
    ) -> [QueryConnectionMenuItem] {
        items(from: ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: connectionStorage.loadConnections(),
            groups: groupStorage.loadGroups(),
            sortMode: listPreferences.sortMode,
            lastConnected: recentConnections.lastConnected
        )))
    }
}

/// The connection a query tab runs on, and what picking another one in the bar does.
///
/// A pick asks first, through the `confirm` the bar is handed: the menu sits a click from the editor,
/// and the move sends the tab's next run elsewhere. A yes moves the tab, the way Database > Move Tab
/// to Connection does, through `move`: `MainContentCoordinator.moveQueryTab(_:toConnection:)`, which
/// ends in `WindowManager.moveQueryTab`, the only route a tab takes between connections.
internal struct QueryConnectionPickerModel {
    internal let connectionId: UUID
    internal let name: String
    internal let color: ConnectionColor
    /// `canMoveTabToConnection`: a running tab, or one whose grid edits would stay behind, keeps its
    /// connection until that is settled.
    internal let canMove: Bool
    /// `MainContentCoordinator.confirmQueryTabMove(_:to:)`: true once the reader agreed to the move.
    internal let confirm: @MainActor (UUID) async -> Bool
    internal let move: @MainActor (UUID) -> Void

    internal var hint: String {
        guard canMove else {
            return String(localized: "This tab cannot move while its query runs or its grid edits are unsaved.")
        }
        return String(format: String(localized: "Runs on %@. Choose another connection to move this tab there."), name)
    }

    @MainActor
    internal func choose(_ id: UUID) async {
        guard canMove, id != connectionId else { return }
        guard await confirm(id) else { return }
        move(id)
    }
}
