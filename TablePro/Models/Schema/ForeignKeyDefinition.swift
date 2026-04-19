//
//  ForeignKeyDefinition.swift
//  TablePro
//
//  Represents a foreign key definition for schema editing.
//

import Foundation
import TableProPluginKit

/// Foreign key definition for schema modification (editable structure tab)
struct EditableForeignKeyDefinition: Hashable, Codable, Identifiable {
    let id: UUID
    var name: String
    var columns: [String]
    var referencedTable: String
    var referencedColumns: [String]
    var referencedSchema: String?
    var onDelete: ReferentialAction
    var onUpdate: ReferentialAction

    enum ReferentialAction: String, Codable, CaseIterable {
        case noAction = "NO ACTION"
        case restrict = "RESTRICT"
        case cascade = "CASCADE"
        case setNull = "SET NULL"
        case setDefault = "SET DEFAULT"
    }

    /// Create a placeholder foreign key for adding new FKs
    static func placeholder() -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(),
            name: "",
            columns: [],
            referencedTable: "",
            referencedColumns: [],
            referencedSchema: nil,
            onDelete: .noAction,
            onUpdate: .noAction
        )
    }

    /// Check if this definition is valid (not a placeholder)
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !columns.isEmpty &&
            !referencedTable.trimmingCharacters(in: .whitespaces).isEmpty &&
            !referencedColumns.isEmpty
    }

    /// Create from existing ForeignKeyInfo
    static func from(_ fkInfo: ForeignKeyInfo) -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: fkInfo.id,
            name: fkInfo.name,
            columns: [fkInfo.column],
            referencedTable: fkInfo.referencedTable,
            referencedColumns: [fkInfo.referencedColumn],
            referencedSchema: fkInfo.referencedSchema,
            onDelete: ReferentialAction(rawValue: fkInfo.onDelete.uppercased()) ?? .noAction,
            onUpdate: ReferentialAction(rawValue: fkInfo.onUpdate.uppercased()) ?? .noAction
        )
    }

    func toPlugin() -> PluginForeignKeyDefinition {
        PluginForeignKeyDefinition(
            name: name, columns: columns, referencedTable: referencedTable,
            referencedColumns: referencedColumns, onDelete: onDelete.rawValue, onUpdate: onUpdate.rawValue,
            referencedSchema: referencedSchema
        )
    }

    /// Convert back to ForeignKeyInfo (single column only)
    func toForeignKeyInfo() -> ForeignKeyInfo? {
        guard let column = columns.first,
              let referencedColumn = referencedColumns.first else {
            return nil
        }

        return ForeignKeyInfo(
            name: name,
            column: column,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn,
            referencedSchema: referencedSchema,
            onDelete: onDelete.rawValue,
            onUpdate: onUpdate.rawValue
        )
    }
}
