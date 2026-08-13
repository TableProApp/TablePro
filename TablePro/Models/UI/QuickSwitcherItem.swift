//
//  QuickSwitcherItem.swift
//  TablePro
//
//  Data model for quick switcher search results
//

import Foundation
import TableProPluginKit

/// The type of database object represented by a quick switcher item
internal enum QuickSwitcherItemKind: String, Hashable, Sendable {
    case table
    case view
    case systemTable
    case database
    case schema
    case savedQuery
    case queryHistory
}

/// How a quick switcher selection should be opened
internal enum QuickSwitcherCommitIntent: Sendable {
    case open
    case openInNewWindowTab
    case openStructure
}

internal struct QuickSwitcherTarget: Hashable, Sendable {
    let connectionId: UUID
    let connectionName: String
    let databaseName: String?
    let schemaName: String?
    let databaseDisplayName: String?
    let pathFieldRole: PathFieldRole

    init(
        connectionId: UUID,
        connectionName: String,
        databaseName: String?,
        schemaName: String?,
        databaseDisplayName: String? = nil,
        pathFieldRole: PathFieldRole = .database
    ) {
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.databaseDisplayName = databaseDisplayName
        self.pathFieldRole = pathFieldRole
    }
}

/// A search scope limiting which kinds of objects the quick switcher shows
internal enum QuickSwitcherScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case tables
    case containers
    case queries
    case connections

    var id: String { rawValue }

    /// Whether the scope draws from the catalog of every connected window rather than
    /// from the objects of the connection that opened the panel.
    var usesCrossConnectionCatalog: Bool { self == .connections }

    var usesCrossConnectionQueries: Bool { self == .queries }

    var includedKinds: Set<QuickSwitcherItemKind>? {
        switch self {
        case .all: return nil
        case .tables: return [.table, .view, .systemTable]
        case .containers: return [.database, .schema]
        case .queries: return [.savedQuery, .queryHistory]
        case .connections: return [.table, .view, .systemTable]
        }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .tables: return String(localized: "Tables")
        case .containers: return String(localized: "Databases")
        case .queries: return String(localized: "Queries")
        case .connections: return String(localized: "Connections")
        }
    }

    var iconName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .tables: return "tablecells"
        case .containers: return "cylinder"
        case .queries: return "doc.text"
        case .connections: return "rectangle.3.group"
        }
    }
}

/// A single item in the quick switcher results list
internal struct QuickSwitcherItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: QuickSwitcherItemKind
    let subtitle: String
    /// Ranked at full weight, unlike the subtitle that carries it for display. A saved query's
    /// subtitle also names its connection and database, and those must not score as strongly as
    /// the keyword the author assigned.
    var keyword: String?
    var matchedIndices: [Int] = []
    var payload: String?
    var isOpenInTab: Bool = false
    var isReadOnly: Bool = false
    var target: QuickSwitcherTarget?

    static func tableItemId(name: String, isView: Bool) -> String {
        "table_\(name)_\(isView ? "VIEW" : "TABLE")"
    }

    /// SF Symbol name for this item's icon
    var iconName: String {
        switch kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .systemTable: return "gearshape"
        case .database: return "cylinder"
        case .schema: return "folder"
        case .savedQuery: return "star"
        case .queryHistory: return "clock.arrow.circlepath"
        }
    }

    /// Localized display label for the item kind
    var kindLabel: String {
        switch kind {
        case .table: return String(localized: "Table")
        case .view: return String(localized: "View")
        case .systemTable: return String(localized: "System Table")
        case .database: return String(localized: "Database")
        case .schema: return String(localized: "Schema")
        case .savedQuery: return String(localized: "Saved Query")
        case .queryHistory: return String(localized: "History")
        }
    }
}
