import Foundation

// MARK: - App-Side Result Types

public struct QueryResult: Sendable {
    public let columns: [ColumnInfo]
    public let rows: [[String?]]
    public let rowsAffected: Int
    public let executionTime: TimeInterval
    public let isTruncated: Bool
    public let statusMessage: String?

    public init(
        columns: [ColumnInfo],
        rows: [[String?]],
        rowsAffected: Int,
        executionTime: TimeInterval,
        isTruncated: Bool = false,
        statusMessage: String? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.executionTime = executionTime
        self.isTruncated = isTruncated
        self.statusMessage = statusMessage
    }
}

public struct ColumnInfo: Sendable, Identifiable {
    public var id: Int { ordinalPosition }
    public let name: String
    public let typeName: String
    public let isPrimaryKey: Bool
    public let isNullable: Bool
    public let defaultValue: String?
    public let comment: String?
    public let characterMaxLength: Int?
    public let ordinalPosition: Int

    public init(
        name: String,
        typeName: String,
        isPrimaryKey: Bool = false,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        comment: String? = nil,
        characterMaxLength: Int? = nil,
        ordinalPosition: Int = 0
    ) {
        self.name = name
        self.typeName = typeName
        self.isPrimaryKey = isPrimaryKey
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.comment = comment
        self.characterMaxLength = characterMaxLength
        self.ordinalPosition = ordinalPosition
    }
}

public struct TableInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let type: TableKind
    public let rowCount: Int?
    public let dataSize: Int?
    public let comment: String?

    public enum TableKind: String, Sendable {
        case table
        case view
        case materializedView
        case systemTable
        case sequence
    }

    public init(
        name: String,
        type: TableKind = .table,
        rowCount: Int? = nil,
        dataSize: Int? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
        self.dataSize = dataSize
        self.comment = comment
    }
}

public struct IndexInfo: Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let type: String

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE"
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
    }
}

public struct ForeignKeyInfo: Sendable {
    public let name: String
    public let column: String
    public let referencedTable: String
    public let referencedColumn: String
    public let referencedSchema: String?
    public let onDelete: String
    public let onUpdate: String

    public init(
        name: String,
        column: String,
        referencedTable: String,
        referencedColumn: String,
        referencedSchema: String? = nil,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.referencedSchema = referencedSchema
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

public enum ConnectionStatus: Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

public struct DatabaseError: Error, LocalizedError, Sendable {
    public let code: Int?
    public let message: String
    public let sqlState: String?

    public var errorDescription: String? { message }

    public init(code: Int? = nil, message: String, sqlState: String? = nil) {
        self.code = code
        self.message = message
        self.sqlState = sqlState
    }
}
