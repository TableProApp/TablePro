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
    case procedure
    case function
    case trigger
    case savedQuery
    case queryHistory
}

/// How a quick switcher selection should be opened
internal enum QuickSwitcherCommitIntent: Equatable, Sendable {
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
    /// The schema of an object in the connection that opened the panel. `target` carries the schema
    /// for a result in another connection and is nil here, so without this a local result committed
    /// with no schema at all: the tab-reuse check compares schemas, so "Switch to Tab" opened a
    /// duplicate of a table that was already open under an explicit schema.
    var schemaName: String?
    /// Set on a routine or trigger row, which opens its source rather than a table tab.
    var objectRef: DatabaseObjectRef?
    var target: QuickSwitcherTarget?

    /// The frecency identity of a table, produced identically by the two places that record one:
    /// the quick switcher, which knows the object's `TableInfo.TableType`, and the tab open
    /// chokepoint, which only ever learns a Bool.
    ///
    /// The type used to be part of this. It cannot be, because the two sides spell it differently
    /// and one of them cannot spell it at all: the switcher used the full `TableType` raw value
    /// while the tab derived `isView` from `allowsRowEditing`, so a materialized view was recorded
    /// as `TABLE` and looked up as `MATERIALIZED VIEW`. Five of the seven table types disagreed,
    /// and those objects could never reach the Recent section or earn a frecency boost no matter
    /// how often they were opened. A name and a schema identify one object in a database whatever
    /// its type, so the type buys nothing here.
    static func tableItemId(name: String, schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return "table_\(name)" }
        return "table_\(schema).\(name)"
    }

    /// SF Symbol name for this item's icon
    var iconName: String {
        switch kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .systemTable: return "gearshape"
        case .database: return "cylinder"
        case .schema: return "folder"
        case .procedure: return "curlybraces.square"
        case .function: return "function"
        case .trigger: return "bolt"
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
        case .procedure: return String(localized: "Procedure")
        case .function: return String(localized: "Function")
        case .trigger: return String(localized: "Trigger")
        case .savedQuery: return String(localized: "Saved Query")
        case .queryHistory: return String(localized: "History")
        }
    }
}
