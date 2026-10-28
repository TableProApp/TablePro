//
//  StructureTab.swift
//  TablePro
//

import Foundation

enum StructureTab: String, CaseIterable, Hashable {
    case columns
    case indexes
    case foreignKeys
    case checkConstraints
    case triggers
    case options
    case ddl
    case parts

    var displayName: String {
        switch self {
        case .columns: String(localized: "Columns")
        case .indexes: String(localized: "Indexes")
        case .foreignKeys: String(localized: "Foreign Keys")
        case .checkConstraints: String(localized: "Constraints")
        case .triggers: String(localized: "Triggers")
        case .options: String(localized: "Options")
        case .ddl: "DDL"
        case .parts: "Parts"
        }
    }
}
