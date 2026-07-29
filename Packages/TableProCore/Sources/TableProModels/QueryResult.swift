import Foundation
import TableProPluginKit

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

// MARK: - Mapping from Plugin Types

public extension QueryResult {
    init(from plugin: PluginQueryResult) {
        let columnInfos = zip(plugin.columns, plugin.columnTypeNames).enumerated().map { index, pair in
            ColumnInfo(
                name: pair.0,
                typeName: pair.1,
                ordinalPosition: index
            )
        }
        let legacyRows: [[String?]] = plugin.rows.map { row in
            row.map { cell -> String? in
                switch cell {
                case .null: return nil
                case .text(let value): return value
                case .bytes(let data): return data.map { String(format: "%02X", $0) }.joined()
                }
            }
        }
        self.init(
            columns: columnInfos,
            rows: legacyRows,
            rowsAffected: plugin.rowsAffected,
            executionTime: plugin.executionTime,
            isTruncated: plugin.isTruncated,
            statusMessage: plugin.statusMessage
        )
    }
}

public extension TableInfo {
    init(from plugin: PluginTableInfo) {
        let kind: TableKind
        switch plugin.type.uppercased() {
        case "TABLE", "BASE TABLE":
            kind = .table
        case "VIEW":
            kind = .view
        case "MATERIALIZED VIEW":
            kind = .materializedView
        case "SYSTEM TABLE":
            kind = .systemTable
        case "SEQUENCE":
            kind = .sequence
        default:
            kind = .table
        }
        self.init(
            name: plugin.name,
            type: kind,
            rowCount: plugin.rowCount
        )
    }
}

public extension ColumnInfo {
    init(from plugin: PluginColumnInfo, ordinalPosition: Int = 0) {
        self.init(
            name: plugin.name,
            typeName: plugin.dataType,
            isPrimaryKey: plugin.isPrimaryKey,
            isNullable: plugin.isNullable,
            defaultValue: plugin.defaultValue,
            comment: plugin.comment,
            ordinalPosition: ordinalPosition
        )
    }
}

public extension IndexInfo {
    init(from plugin: PluginIndexInfo) {
        self.init(
            name: plugin.name,
            columns: plugin.columns,
            isUnique: plugin.isUnique,
            isPrimary: plugin.isPrimary,
            type: plugin.type
        )
    }
}

public extension ForeignKeyInfo {
    init(from plugin: PluginForeignKeyInfo) {
        self.init(
            name: plugin.name,
            column: plugin.column,
            referencedTable: plugin.referencedTable,
            referencedColumn: plugin.referencedColumn,
            referencedSchema: plugin.referencedSchema,
            onDelete: plugin.onDelete,
            onUpdate: plugin.onUpdate
        )
    }
}
