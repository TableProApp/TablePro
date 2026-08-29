//
//  StructureTab.swift
//  TablePro
//
//  Tab selection for structure view
//

import Foundation

/// Tab selection for structure view
enum StructureTab: String, CaseIterable, Hashable {
    case properties
    case columns
    case indexes
    case foreignKeys
    case checkConstraints
    case triggers
    case ddl
    case parts

    var displayName: String {
        switch self {
        case .properties: String(localized: "Properties")
        case .columns: String(localized: "Columns")
        case .indexes: String(localized: "Indexes")
        case .foreignKeys: String(localized: "Foreign Keys")
        case .checkConstraints: String(localized: "Constraints")
        case .triggers: String(localized: "Triggers")
        case .ddl: "DDL"
        case .parts: "Parts"
        }
    }
}
