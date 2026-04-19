import Foundation

public struct PluginColumnDefinition: Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    public let defaultValue: String?
    public let isPrimaryKey: Bool
    public let autoIncrement: Bool
    public let comment: String?
    public let unsigned: Bool
    public let onUpdate: String?
    public let charset: String?
    public let collation: String?

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
    }
}

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
