import Foundation

public struct SpannerTableInfo: Sendable, Equatable {
    public let schema: String
    public let name: String
    public let isView: Bool

    public init(schema: String, name: String, isView: Bool) {
        self.schema = schema
        self.name = name
        self.isView = isView
    }
}

public struct SpannerColumnInfo: Sendable, Equatable {
    public let schema: String
    public let table: String
    public let name: String
    public let spannerType: String
    public let isNullable: Bool
    public let isPrimaryKey: Bool
    public let defaultExpression: String?
    public let isGenerated: Bool
    public let generationExpression: String?
    public let isStored: Bool
    public let identityGeneration: String?
    public let isHidden: Bool

    public init(
        schema: String,
        table: String,
        name: String,
        spannerType: String,
        isNullable: Bool,
        isPrimaryKey: Bool,
        defaultExpression: String? = nil,
        isGenerated: Bool = false,
        generationExpression: String? = nil,
        isStored: Bool = false,
        identityGeneration: String? = nil,
        isHidden: Bool = false
    ) {
        self.schema = schema
        self.table = table
        self.name = name
        self.spannerType = spannerType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultExpression = defaultExpression
        self.isGenerated = isGenerated
        self.generationExpression = generationExpression
        self.isStored = isStored
        self.identityGeneration = identityGeneration
        self.isHidden = isHidden
    }
}

public struct SpannerIndexInfo: Sendable, Equatable {
    public let schema: String
    public let table: String
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimaryKey: Bool
    public let isManaged: Bool
    public let type: String

    public init(
        schema: String,
        table: String,
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimaryKey: Bool,
        isManaged: Bool,
        type: String
    ) {
        self.schema = schema
        self.table = table
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimaryKey = isPrimaryKey
        self.isManaged = isManaged
        self.type = type
    }
}

public struct SpannerForeignKeyInfo: Sendable, Equatable {
    public let schema: String
    public let table: String
    public let name: String
    public let columns: [String]
    public let referencedSchema: String
    public let referencedTable: String
    public let referencedColumns: [String]
    public let onDelete: String?
    public let isInterleave: Bool

    public init(
        schema: String,
        table: String,
        name: String,
        columns: [String],
        referencedSchema: String,
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String?,
        isInterleave: Bool
    ) {
        self.schema = schema
        self.table = table
        self.name = name
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.isInterleave = isInterleave
    }
}
