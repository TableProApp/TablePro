//
//  QuickSwitcherItem.swift
//  TablePro
//
//  Data model for quick switcher search results
//

import Foundation

/// The type of database object represented by a quick switcher item
internal enum QuickSwitcherItemKind: Hashable, Sendable {
    case table
    case view
    case systemTable
    case database
    case schema
    case queryHistory
}

/// A single item in the quick switcher results list
internal struct QuickSwitcherItem: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: QuickSwitcherItemKind
    let subtitle: String
    var score: Int = 0

    /// SF Symbol name for this item's icon
    var iconName: String {
        switch kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .systemTable: return "gearshape"
        case .database: return "cylinder"
        case .schema: return "folder"
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
        case .queryHistory: return String(localized: "History")
        }
    }
}
