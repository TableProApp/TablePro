//
//  QueryResult.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation

/// Represents a row of query results for UI display
struct QueryResultRow: Identifiable, Equatable {
    let id: Int
    var values: [String?]

    static func == (lhs: QueryResultRow, rhs: QueryResultRow) -> Bool {
        lhs.id == rhs.id && lhs.values == rhs.values
    }
}

/// Result of a database query execution
struct QueryResult {
    let columns: [String]
    let columnTypes: [ColumnType]  // NEW: Type metadata for each column
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let error: DatabaseError?

    /// Whether the result was truncated due to driver-level row limits
    var isTruncated: Bool = false

    var isEmpty: Bool {
        rows.isEmpty
    }

    var rowCount: Int {
        rows.count
    }

    var columnCount: Int {
        columns.count
    }

    /// Convert to QueryResultRow format for UI
    func toQueryResultRows() -> [QueryResultRow] {
        rows.enumerated().map { index, row in
            QueryResultRow(id: index, values: row)
        }
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
            return String(localized: "Database file not found: \(path)")
        case .notConnected:
            return String(localized: "Not connected to database")
        case .unsupportedOperation:
            return String(localized: "This operation is not supported")
        }
    }
}

/// Information about a database table
struct TableInfo: Identifiable, Hashable {
    var id: String { "\(name)_\(type.rawValue)" }
    let name: String
    let type: TableType
    let rowCount: Int?

    enum TableType: String, Sendable {
        case table = "TABLE"
        case view = "VIEW"
        case systemTable = "SYSTEM TABLE"
    }

    static func == (lhs: TableInfo, rhs: TableInfo) -> Bool {
        lhs.name == rhs.name && lhs.type == rhs.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(type)
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
}

/// Information about a table index
struct IndexInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let columns: [String]
    let isUnique: Bool
    let isPrimary: Bool
    let type: String  // BTREE, HASH, FULLTEXT, etc.
}

/// Information about a foreign key relationship
struct ForeignKeyInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let column: String
    let referencedTable: String
    let referencedColumn: String
    let onDelete: String  // CASCADE, SET NULL, RESTRICT, NO ACTION
    let onUpdate: String
}

/// Connection status
enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
