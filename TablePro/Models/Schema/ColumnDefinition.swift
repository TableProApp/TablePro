//
//  ColumnDefinition.swift
//  TablePro
//
//  Represents a column definition for schema editing.
//

import Foundation
import TableProPluginKit

/// Column definition for schema modification (editable structure tab)
struct EditableColumnDefinition: Hashable, Codable, Identifiable {
    let id: UUID
    var name: String
    var dataType: String
    var isNullable: Bool
    var defaultValue: String?
    var autoIncrement: Bool
    var unsigned: Bool  // MySQL only
    var comment: String?
    var collation: String?
    var onUpdate: String?  // MySQL timestamp columns
    var charset: String?
    var extra: String?

    var isPrimaryKey: Bool

    /// Create a placeholder column for adding new columns
    static func placeholder() -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: "",
            dataType: "",
            isNullable: true,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
    }

    /// Check if this definition is valid (not a placeholder)
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !dataType.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Create from existing ColumnInfo
    static func from(_ columnInfo: ColumnInfo) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: columnInfo.id,
            name: columnInfo.name,
            dataType: columnInfo.dataType,
            isNullable: columnInfo.isNullable,
            defaultValue: columnInfo.defaultValue,
            autoIncrement: columnInfo.extra?.lowercased().contains("auto_increment") == true
                || columnInfo.extra == "IDENTITY",
            unsigned: columnInfo.dataType.contains("unsigned"),
            comment: columnInfo.comment,
            collation: columnInfo.collation,
            onUpdate: nil,
            charset: columnInfo.charset,
            extra: columnInfo.extra,
            isPrimaryKey: columnInfo.isPrimaryKey
        )
    }

    func toPlugin() -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: name, dataType: dataType, isNullable: isNullable, defaultValue: defaultValue,
            isPrimaryKey: isPrimaryKey, autoIncrement: autoIncrement, comment: comment,
            unsigned: unsigned, onUpdate: onUpdate, charset: charset, collation: collation
        )
    }

    /// Convert back to ColumnInfo
    func toColumnInfo() -> ColumnInfo {
        ColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: extra,
            charset: charset,
            collation: collation,
            comment: comment
        )
    }
}
