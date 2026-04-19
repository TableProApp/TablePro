//
//  StructureTab.swift
//  TablePro
//
//  Tab selection for structure view
//

import Foundation

/// Tab selection for structure view
enum StructureTab: String, CaseIterable, Hashable {
    case columns
    case indexes
    case foreignKeys
    case ddl
    case parts

    var displayName: String {
        switch self {
        case .columns: String(localized: "Columns")
        case .indexes: String(localized: "Indexes")
        case .foreignKeys: String(localized: "Foreign Keys")
        case .ddl: "DDL"
        case .parts: "Parts"
        }
    }
}
