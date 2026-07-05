//
//  QuickSwitcherItem.swift
//  TablePro
//
//  Data model for quick switcher search results
//

import Foundation

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

/// A search scope limiting which kinds of objects the quick switcher shows
internal enum QuickSwitcherScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case tables
    case containers
    case queries

    var id: String { rawValue }

    var includedKinds: Set<QuickSwitcherItemKind>? {
        switch self {
        case .all: return nil
        case .tables: return [.table, .view, .systemTable]
        case .containers: return [.database, .schema]
        case .queries: return [.savedQuery, .queryHistory]
        }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .tables: return String(localized: "Tables")
        case .containers: return String(localized: "Databases")
        case .queries: return String(localized: "Queries")
        }
    }

    var iconName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .tables: return "tablecells"
        case .containers: return "cylinder"
        case .queries: return "doc.text"
        }
    }
}

/// A single item in the quick switcher results list
internal struct QuickSwitcherItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: QuickSwitcherItemKind
    let subtitle: String
    var matchedIndices: [Int] = []
    var payload: String?
    var isOpenInTab: Bool = false

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
