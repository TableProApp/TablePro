//
//  QueryResult.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import TableProPluginKit

struct QueryResult {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let error: DatabaseError?

    /// Whether the result was truncated due to driver-level row limits
    var isTruncated: Bool = false

    /// Optional status message from the plugin (e.g. server notices, warnings)
    var statusMessage: String?

    var columnMeta: [ResultColumnMeta]?

    var isEmpty: Bool {
        rows.isEmpty
    }

    var rowCount: Int {
        rows.count
    }

    var columnCount: Int {
        columns.count
    }

    static let empty = QueryResult(
        columns: [],
        columnTypes: [],
        rows: [],
        rowsAffected: 0,
        executionTime: 0,
        error: nil
    )
}

struct ResultColumnMeta: Sendable {
    let isPrimaryKey: Bool
    let isNullable: Bool
    let isAutoIncrement: Bool
}

/// Database error types
enum DatabaseError: Error, LocalizedError {
    case connectionFailed(String)
    case queryFailed(String)
    case invalidCredentials
    case fileNotFound(String)
    case notConnected
    case unsupportedOperation

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return message
        case .queryFailed(let message):
            return message
        case .invalidCredentials:
            return String(localized: "Invalid username or password")
        case .fileNotFound(let path):
            return String(format: String(localized: "Database file not found: %@"), path)
        case .notConnected:
            return String(localized: "Not connected to database")
        case .unsupportedOperation:
            return String(localized: "This operation is not supported")
        }
    }
}

/// Information about a database table
struct TableInfo: Identifiable, Hashable, Sendable {
    var id: String {
        if let schema, !schema.isEmpty {
            return "\(schema).\(name)_\(type.rawValue)"
        }
        return "\(name)_\(type.rawValue)"
    }
    let name: String
    let type: TableType
    let rowCount: Int?
    let schema: String?

    enum TableType: String, Sendable {
        case table = "TABLE"
        case view = "VIEW"
        case materializedView = "MATERIALIZED VIEW"
        case foreignTable = "FOREIGN TABLE"
        case systemTable = "SYSTEM TABLE"
    }

    init(name: String, type: TableType, rowCount: Int?, schema: String? = nil) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
        self.schema = schema
    }

    static func == (lhs: TableInfo, rhs: TableInfo) -> Bool {
        lhs.name == rhs.name && lhs.type == rhs.type && lhs.schema == rhs.schema
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(type)
        hasher.combine(schema)
    }
}

/// Information about a table column
struct ColumnInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let defaultValue: String?
    let extra: String?
    let charset: String?
    let collation: String?
    let comment: String?
    let allowedValues: [String]?

    init(
        name: String,
        dataType: String,
        isNullable: Bool,
        isPrimaryKey: Bool,
        defaultValue: String? = nil,
        extra: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        comment: String? = nil,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.charset = charset
        self.collation = collation
        self.comment = comment
        self.allowedValues = allowedValues
    }
}

/// Information about a table index
struct IndexInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let columns: [String]
    let isUnique: Bool
    let isPrimary: Bool
    let type: String  // BTREE, HASH, FULLTEXT, etc.
    let columnPrefixes: [String: Int]?
    let whereClause: String?

    init(
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimary: Bool,
        type: String,
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
    }
}

/// Information about a foreign key relationship
struct ForeignKeyInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let column: String
    let referencedTable: String
    let referencedColumn: String
    let referencedSchema: String?
    let onDelete: String  // CASCADE, SET NULL, RESTRICT, NO ACTION
    let onUpdate: String

    init(
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

struct TriggerInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let timing: String
    let event: String
    let statement: String
    let enabled: Bool?

    init(
        name: String,
        timing: String,
        event: String,
        statement: String,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.timing = timing
        self.event = event
        self.statement = statement
        self.enabled = enabled
    }
}

/// Connection status
enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
