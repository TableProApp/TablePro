//
//  ConnectionNavigatorRow.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

/// A navigator row's identity. A connection appears once, in its own group, so its id alone names
/// its row; Favorites and Recent, where the Welcome list repeats a connection, are not shown here.
internal enum ConnectionNavigatorRowID: Hashable, Sendable {
    case group(UUID)
    case connection(UUID)
}

/// Where a connection stands relative to the window drawing the navigator, which decides what a
/// click does and what the row is marked with.
internal enum ConnectionNavigatorPlacement: Equatable, Sendable {
    case shownHere
    case openHere
    case openElsewhere
    case notOpen
}

internal struct ConnectionNavigatorGroupRow: Equatable {
    internal let id: UUID
    internal let name: String
    internal let color: ConnectionColor
    internal let iconName: String?
    internal let connectionCount: Int
    /// A collapsed group keeps its children, so the outline can open it without a rebuild.
    internal let isExpanded: Bool
    internal let children: [ConnectionNavigatorRow]
}

internal struct ConnectionNavigatorConnectionRow: Equatable {
    internal let connection: DatabaseConnection
    internal let groupPath: [String]
    internal let isDriverRejected: Bool
    internal var status: ConnectionDisplayStatus
    internal var placement: ConnectionNavigatorPlacement

    internal var id: UUID { connection.id }
}

internal enum ConnectionNavigatorRow: Equatable {
    case group(ConnectionNavigatorGroupRow)
    case connection(ConnectionNavigatorConnectionRow)

    internal var id: ConnectionNavigatorRowID {
        switch self {
        case .group(let group): return .group(group.id)
        case .connection(let connection): return .connection(connection.id)
        }
    }

    internal var children: [ConnectionNavigatorRow] {
        switch self {
        case .group(let group): return group.children
        case .connection: return []
        }
    }

    /// What type-select matches and VoiceOver reads for the row.
    internal var name: String {
        switch self {
        case .group(let group): return group.name
        case .connection(let connection): return connection.connection.name
        }
    }
}
