//
//  StructureTab.swift
//  TablePro
//
//  Tab selection for structure view
//

import Foundation

/// Tab selection for structure view
enum StructureTab: String, CaseIterable, Hashable {
    case columns = "Columns"
    case indexes = "Indexes"
    case foreignKeys = "Foreign Keys"
    case ddl = "DDL"
    case parts = "Parts"
}
