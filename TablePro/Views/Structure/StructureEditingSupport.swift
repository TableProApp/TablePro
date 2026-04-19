//
//  StructureEditingSupport.swift
//  TablePro
//
//  Shared editing logic for updating structure entities by column index.
//  Used by both TableStructureView and CreateTableView to avoid
//  duplicated hardcoded index-to-field switch statements.
//

import Foundation
import TableProPluginKit

@MainActor
enum StructureEditingSupport {
    static func updateColumn(
        _ column: inout EditableColumnDefinition,
        at index: Int,
        with value: String,
        orderedFields: [StructureColumnField]
    ) {
        guard index >= 0, index < orderedFields.count else { return }
        switch orderedFields[index] {
        case .name: column.name = value
        case .type: column.dataType = value
        case .nullable: column.isNullable = value.uppercased() == "YES" || value == "1"
        case .defaultValue: column.defaultValue = value.isEmpty ? nil : value
        case .primaryKey: column.isPrimaryKey = value.uppercased() == "YES" || value == "1"
        case .autoIncrement: column.autoIncrement = value.uppercased() == "YES" || value == "1"
        case .comment: column.comment = value.isEmpty ? nil : value
        }
    }

    static func updateIndex(_ index: inout EditableIndexDefinition, at colIndex: Int, with value: String) {
        switch colIndex {
        case 0: index.name = value
        case 1: index.columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 2:
            if let indexType = EditableIndexDefinition.IndexType(rawValue: value.uppercased()) {
                index.type = indexType
            }
        case 3: index.isUnique = value.uppercased() == "YES" || value == "1"
        default: break
        }
    }

    static func updateForeignKey(_ fk: inout EditableForeignKeyDefinition, at index: Int, with value: String) {
        switch index {
        case 0: fk.name = value
        case 1: fk.columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 2: fk.referencedTable = value
        case 3: fk.referencedColumns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 4:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onDelete = action
            }
        case 5:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onUpdate = action
            }
        default: break
        }
    }
}
