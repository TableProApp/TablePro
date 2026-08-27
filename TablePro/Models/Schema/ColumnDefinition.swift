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
    var id: UUID
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
    var generationExpression: String?
    var generationKind: GenerationKind?

    var isPrimaryKey: Bool

    static let currentTimestampExpression = "CURRENT_TIMESTAMP"

    /// Spelled out rather than left to the memberwise init so the two generation fields can carry
    /// defaults. `redundant_optional_initialization` is on under `swiftlint --strict`, so `= nil`
    /// on the stored properties is not an option.
    init(
        id: UUID,
        name: String,
        dataType: String,
        isNullable: Bool,
        defaultValue: String?,
        autoIncrement: Bool,
        unsigned: Bool,
        comment: String?,
        collation: String?,
        onUpdate: String?,
        charset: String?,
        extra: String?,
        generationExpression: String? = nil,
        generationKind: GenerationKind? = nil,
        isPrimaryKey: Bool
    ) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.autoIncrement = autoIncrement
        self.unsigned = unsigned
        self.comment = comment
        self.collation = collation
        self.onUpdate = onUpdate
        self.charset = charset
        self.extra = extra
        self.generationExpression = generationExpression
        self.generationKind = generationKind
        self.isPrimaryKey = isPrimaryKey
    }

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

    var isGenerated: Bool { generationExpression?.isEmpty == false }

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
            onUpdate: onUpdateExpression(fromExtra: columnInfo.extra),
            charset: columnInfo.charset,
            extra: columnInfo.extra,
            generationExpression: columnInfo.generationExpression,
            generationKind: columnInfo.generationKind,
            isPrimaryKey: columnInfo.isPrimaryKey
        )
    }

    /// Normalised to the bare expression: fractional-second precision is redundant with the
    /// column's declared type and is re-derived when generating DDL.
    private static func onUpdateExpression(fromExtra extra: String?) -> String? {
        guard let extra, extra.lowercased().contains("on update") else { return nil }
        return currentTimestampExpression
    }

    func toPlugin() -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: name, dataType: dataType, isNullable: isNullable, defaultValue: defaultValue,
            isPrimaryKey: isPrimaryKey, autoIncrement: autoIncrement, comment: comment,
            unsigned: unsigned, onUpdate: onUpdate, charset: charset, collation: collation,
            generationExpression: generationExpression, generationKind: generationKind
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
            comment: comment,
            isGenerated: isGenerated,
            generationExpression: generationExpression,
            generationKind: generationKind
        )
    }

    /// A copy under a fresh identity, for paste and duplicate. Assigning `id` rather than
    /// re-listing every property is what stops a newly added field being silently dropped here.
    func withNewIdentity() -> EditableColumnDefinition {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
