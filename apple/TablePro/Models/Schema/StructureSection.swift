//
//  StructureSection.swift
//  TablePro
//

import Foundation

// The kinds of definition a table's structure stages edits for. Read-only panes are StructurePane.
enum StructureSection: String, CaseIterable, Hashable {
    case columns
    case indexes
    case foreignKeys
    case checkConstraints

    var displayName: String {
        switch self {
        case .columns: String(localized: "Columns")
        case .indexes: String(localized: "Indexes")
        case .foreignKeys: String(localized: "Foreign Keys")
        case .checkConstraints: String(localized: "Check Constraints")
        }
    }
}

enum StructurePane: String, CaseIterable, Hashable {
    case definition
    case triggers
    case ddl
    case parts

    var displayName: String {
        switch self {
        case .definition: String(localized: "Definition")
        case .triggers: String(localized: "Triggers")
        case .ddl: "DDL"
        case .parts: "Parts"
        }
    }
}
