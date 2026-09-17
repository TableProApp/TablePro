//
//  SchemaTypes.swift
//  TableProPluginKit
//
//  Transfer types for DDL schema operations.
//

import Foundation

/// Column definition for plugin DDL generation
public struct PluginColumnDefinition: Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    /// The exact SQL that follows the `DEFAULT` keyword, or nil for no `DEFAULT` clause at all.
    ///
    /// A literal carries its own quotes (`'abc'`, `''`), an expression is written the way the engine
    /// spells it (`now()`, `gen_random_uuid()`, `(datetime('now'))`), and `NULL` means `DEFAULT NULL`
    /// rather than the absence of a default. A driver emits this verbatim and never re-quotes it.
    ///
    /// It used to be untyped text, which left every writer guessing literal from expression against a
    /// hand-copied allowlist. Measured, that turned `gen_random_uuid()` into an eleven-character
    /// string and `nextval('t_id_seq'::regclass)` into a value PostgreSQL rejects. Adding required
    /// syntax the engine's own grammar demands is still the driver's job: MySQL takes a `TEXT`
    /// default only in parentheses, whatever the value is.
    public let defaultValue: String?
    public let isPrimaryKey: Bool
    public let autoIncrement: Bool
    public let comment: String?
    public let unsigned: Bool
    public let onUpdate: String?
    public let charset: String?
    public let collation: String?
    public let generationExpression: String?
    public let generationKind: GenerationKind?
    /// The server's own spelling of `dataType` for a `CREATE TABLE`, or nil to write `dataType`.
    /// `PluginColumnInfo.ddlSpelling` says why the two differ.
    public let ddlSpelling: String?
    /// The server's own spelling of `defaultValue` for a `CREATE TABLE`, or nil to write `defaultValue`.
    public let ddlDefault: String?
    /// The server's own spelling of `generationExpression` for a `CREATE TABLE`, or nil to write
    /// `generationExpression`.
    public let ddlGenerationExpression: String?
    /// What follows `COLLATE` in a `CREATE TABLE`, or nil to write no `COLLATE` clause.
    /// `PluginColumnInfo.ddlCollation` says why it is not `collation`.
    public let ddlCollation: String?

    /// The signature published before generated-column detail existed. Kept byte-identical and
    /// disfavoured so already-built plugins keep resolving their own mangled symbol.
    @_disfavoredOverload
    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        autoIncrement: Bool = false,
        comment: String? = nil,
        unsigned: Bool = false,
        onUpdate: String? = nil,
        charset: String? = nil,
        collation: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.autoIncrement = autoIncrement
        self.comment = comment
        self.unsigned = unsigned
        self.onUpdate = onUpdate
        self.charset = charset
        self.collation = collation
        self.generationExpression = nil
        self.generationKind = nil
        self.ddlSpelling = nil
        self.ddlDefault = nil
        self.ddlGenerationExpression = nil
        self.ddlCollation = nil
    }

    /// The signature published before the DDL spellings existed, kept byte-identical and disfavoured
    /// for the same reason as the one above.
    @_disfavoredOverload
    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        autoIncrement: Bool = false,
        comment: String? = nil,
        unsigned: Bool = false,
        onUpdate: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        generationExpression: String?,
        generationKind: GenerationKind?
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.autoIncrement = autoIncrement
        self.comment = comment
        self.unsigned = unsigned
        self.onUpdate = onUpdate
        self.charset = charset
        self.collation = collation
        self.generationExpression = generationExpression
        self.generationKind = generationKind
        self.ddlSpelling = nil
        self.ddlDefault = nil
        self.ddlGenerationExpression = nil
        self.ddlCollation = nil
    }

    /// The signature published before `ddlCollation` existed, kept byte-identical and disfavoured for
    /// the same reason as the ones above.
    @_disfavoredOverload
    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        autoIncrement: Bool = false,
        comment: String? = nil,
        unsigned: Bool = false,
        onUpdate: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        generationExpression: String?,
        generationKind: GenerationKind?,
        ddlSpelling: String?,
        ddlDefault: String?,
        ddlGenerationExpression: String?
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.autoIncrement = autoIncrement
        self.comment = comment
        self.unsigned = unsigned
        self.onUpdate = onUpdate
        self.charset = charset
        self.collation = collation
        self.generationExpression = generationExpression
        self.generationKind = generationKind
        self.ddlSpelling = ddlSpelling
        self.ddlDefault = ddlDefault
        self.ddlGenerationExpression = ddlGenerationExpression
        self.ddlCollation = nil
    }

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        autoIncrement: Bool = false,
        comment: String? = nil,
        unsigned: Bool = false,
        onUpdate: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        generationExpression: String?,
        generationKind: GenerationKind?,
        ddlSpelling: String?,
        ddlDefault: String?,
        ddlGenerationExpression: String?,
        ddlCollation: String?
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.autoIncrement = autoIncrement
        self.comment = comment
        self.unsigned = unsigned
        self.onUpdate = onUpdate
        self.charset = charset
        self.collation = collation
        self.generationExpression = generationExpression
        self.generationKind = generationKind
        self.ddlSpelling = ddlSpelling
        self.ddlDefault = ddlDefault
        self.ddlGenerationExpression = ddlGenerationExpression
        self.ddlCollation = ddlCollation
    }

    public var isGenerated: Bool { generationExpression?.isEmpty == false }
}

/// Check constraint definition for plugin DDL generation
public struct PluginCheckConstraintDefinition: Sendable {
    public let name: String
    public let expression: String

    public init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

/// Index definition for plugin DDL generation
public struct PluginIndexDefinition: Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let indexType: String?
    public let columnPrefixes: [String: Int]?
    public let whereClause: String?

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        indexType: String? = nil,
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.indexType = indexType
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
    }
}

/// Foreign key definition for plugin DDL generation
public struct PluginForeignKeyDefinition: Sendable {
    public let name: String
    public let columns: [String]
    public let referencedTable: String
    public let referencedColumns: [String]
    public let onDelete: String
    public let onUpdate: String
    public let referencedSchema: String?

    public init(
        name: String,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION",
        referencedSchema: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.referencedSchema = referencedSchema
    }
}

/// Full table definition for CREATE TABLE DDL generation
public struct PluginCreateTableDefinition: Sendable {
    public let tableName: String
    public let columns: [PluginColumnDefinition]
    public let indexes: [PluginIndexDefinition]
    public let foreignKeys: [PluginForeignKeyDefinition]
    public let primaryKeyColumns: [String]
    public let engine: String?
    public let charset: String?
    public let collation: String?
    public let ifNotExists: Bool

    public init(
        tableName: String,
        columns: [PluginColumnDefinition],
        indexes: [PluginIndexDefinition] = [],
        foreignKeys: [PluginForeignKeyDefinition] = [],
        primaryKeyColumns: [String] = [],
        engine: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        ifNotExists: Bool = false
    ) {
        self.tableName = tableName
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.primaryKeyColumns = primaryKeyColumns
        self.engine = engine
        self.charset = charset
        self.collation = collation
        self.ifNotExists = ifNotExists
    }
}
