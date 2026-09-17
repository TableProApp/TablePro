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

    /// The server's own spellings of `dataType`, `defaultValue`, `generationExpression` and
    /// `collation` for a `CREATE TABLE`, carried from the catalog read.
    ///
    /// Each applies only while its field still holds the value it was read with. An edit in the
    /// structure editor changes the field, and a spelling that outlived it would recreate the column
    /// as it used to be. The pair is stored rather than cleared on edit, so changing a type and
    /// changing it back restores the spelling and leaves the column equal to the one loaded: cleared,
    /// that column stayed staged as a change no statement could express, and the save was refused.
    ///
    /// Not encoded. A column pasted from the clipboard can come from another connection, where a
    /// `public.geometry` names a schema this one may not have.
    var ddlSpelling: String? { catalogType?.spelling(for: dataType) }
    var ddlDefault: String? { catalogDefault?.spelling(for: defaultValue) }
    var ddlGenerationExpression: String? { catalogGeneration?.spelling(for: generationExpression) }
    /// Paired with a `collation` that can be nil: PostgreSQL shows no collation name for a column
    /// declared `COLLATE "default"` over a type whose own collation is `C`, and that column still
    /// has one to write.
    var ddlCollation: String? { catalogCollation?.spelling(for: collation) }
    /// Paired with `dataType` like the spellings above: a type typed into the structure editor is
    /// classified as the user wrote it, and the catalog's hint returns if the edit is undone.
    var classificationTypeName: String? { catalogClassification?.spelling(for: dataType) }

    /// What a classifier reads. `ColumnInfo.typeNameForClassification` says why it is not `dataType`.
    var typeNameForClassification: String { classificationTypeName ?? dataType }

    private var catalogType: CatalogSpelling<String>?
    private var catalogDefault: CatalogSpelling<String>?
    private var catalogGeneration: CatalogSpelling<String>?
    private var catalogCollation: CatalogSpelling<String?>?
    private var catalogClassification: CatalogSpelling<String>?

    private enum CodingKeys: String, CodingKey {
        case id, name, dataType, isNullable, defaultValue, autoIncrement, unsigned, comment, collation
        case onUpdate, charset, extra, generationExpression, generationKind, isPrimaryKey
    }

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
        isPrimaryKey: Bool,
        ddlSpelling: String? = nil,
        ddlDefault: String? = nil,
        ddlGenerationExpression: String? = nil,
        ddlCollation: String? = nil,
        classificationTypeName: String? = nil
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
        self.catalogType = ddlSpelling.map { CatalogSpelling(value: dataType, spelling: $0) }
        self.catalogDefault = Self.catalogSpelling(value: defaultValue, spelling: ddlDefault)
        self.catalogGeneration = Self.catalogSpelling(value: generationExpression, spelling: ddlGenerationExpression)
        self.catalogCollation = ddlCollation.map { CatalogSpelling(value: collation, spelling: $0) }
        self.catalogClassification = classificationTypeName.map { CatalogSpelling(value: dataType, spelling: $0) }
    }

    private static func catalogSpelling(value: String?, spelling: String?) -> CatalogSpelling<String>? {
        guard let value, let spelling else { return nil }
        return CatalogSpelling(value: value, spelling: spelling)
    }

    /// For a column said again in another engine's words, where none of this server's spellings
    /// name anything the target has. The classification hint stays: it names a kind, not an object,
    /// and a domain column still holds an integer wherever it is written.
    mutating func dropCatalogSpellings() {
        catalogType = nil
        catalogDefault = nil
        catalogGeneration = nil
        catalogCollation = nil
    }

    /// The same column holding `other`'s character set and collation, with the catalog spelling
    /// that goes with them.
    ///
    /// For a comparison that reports no collation difference: a column changed for some other reason
    /// is rewritten whole on engines that restate the column to alter it, and with the source's
    /// collation in it that rewrite changed a collation the comparison had left alone. Only for a
    /// column of `other`'s type: a collation is read on its type, and `INT CHARACTER SET utf8mb4` is
    /// a syntax error.
    func keepingCollation(of other: EditableColumnDefinition) -> EditableColumnDefinition {
        var copy = self
        copy.charset = other.charset
        copy.collation = other.collation
        copy.catalogCollation = other.catalogCollation
        return copy
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
            isPrimaryKey: columnInfo.isPrimaryKey,
            ddlSpelling: columnInfo.ddlSpelling,
            ddlDefault: columnInfo.ddlDefault,
            ddlGenerationExpression: columnInfo.ddlGenerationExpression,
            ddlCollation: columnInfo.ddlCollation,
            classificationTypeName: columnInfo.classificationTypeName
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
            generationExpression: generationExpression, generationKind: generationKind,
            ddlSpelling: ddlSpelling,
            ddlDefault: ddlDefault,
            ddlGenerationExpression: ddlGenerationExpression,
            ddlCollation: ddlCollation
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
            generationKind: generationKind,
            ddlSpelling: ddlSpelling,
            ddlDefault: ddlDefault,
            ddlGenerationExpression: ddlGenerationExpression,
            ddlCollation: ddlCollation,
            classificationTypeName: classificationTypeName
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
