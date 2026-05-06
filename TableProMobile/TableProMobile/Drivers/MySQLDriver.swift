//
//  MySQLDriver.swift
//  TableProMobile
//
//  MySQL driver conforming to DatabaseDriver directly (no plugin layer).
//

import CMariaDB
import Foundation
import TableProDatabase
import TableProModels

final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    private let actor = MySQLActor()
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    let sslEnabled: Bool

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { true }

    // Set once during connect() before the driver is shared — safe for concurrent reads
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(host: String, port: Int, user: String, password: String, database: String, sslEnabled: Bool = false) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslEnabled = sslEnabled
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(host: host, port: port, user: user, password: password, database: database, sslEnabled: sslEnabled)
        serverVersion = await actor.serverVersion()
    }

    func disconnect() async throws {
        await actor.close()
    }

    func ping() async throws -> Bool {
        try await actor.ping()
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let raw = try await actor.execute(query)
        return QueryResult(
            columns: raw.columns.enumerated().map { i, name in
                ColumnInfo(
                    name: name,
                    typeName: i < raw.columnTypes.count ? raw.columnTypes[i] : "",
                    isPrimaryKey: false,
                    isNullable: true,
                    defaultValue: nil,
                    comment: nil,
                    characterMaxLength: nil,
                    ordinalPosition: i
                )
            },
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated,
            statusMessage: nil
        )
    }

    func cancelCurrentQuery() async throws {
        // MySQL C API does not support async cancel without a second connection.
        // No-op for mobile.
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let raw = try await actor.execute("SHOW FULL TABLES")

        return raw.rows.compactMap { row in
            guard row.count >= 2, let name = row[0], let typeStr = row[1] else { return nil }
            let kind: TableInfo.TableKind = typeStr.uppercased() == "VIEW" ? .view : .table
            return TableInfo(name: name, type: kind, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let safe = table.replacingOccurrences(of: "`", with: "``")
        let raw = try await actor.execute("SHOW FULL COLUMNS FROM `\(safe)`")

        return raw.rows.enumerated().compactMap { index, row in
            guard row.count >= 9, let name = row[0], let dataType = row[1] else { return nil }
            let isPK = row[4]?.uppercased().contains("PRI") == true
            let isNullable = row[3]?.uppercased() == "YES"
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: isPK,
                isNullable: isNullable,
                defaultValue: row[5],
                comment: row[8],
                characterMaxLength: nil,
                ordinalPosition: index
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let safe = table.replacingOccurrences(of: "`", with: "``")
        let raw = try await actor.execute("SHOW INDEX FROM `\(safe)`")

        var indexMap: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])] = [:]
        var order: [String] = []

        for row in raw.rows {
            guard row.count >= 5, let keyName = row[2], let colName = row[4] else { continue }
            if indexMap[keyName] == nil {
                indexMap[keyName] = (
                    isUnique: row[1] == "0",
                    isPrimary: keyName == "PRIMARY",
                    columns: []
                )
                order.append(keyName)
            }
            indexMap[keyName]?.columns.append(colName)
        }

        return order.compactMap { name in
            guard let entry = indexMap[name] else { return nil }
            return IndexInfo(
                name: name,
                columns: entry.columns,
                isUnique: entry.isUnique,
                isPrimary: entry.isPrimary,
                type: "BTREE"
            )
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let safe = table.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        let dbSafe = database.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        let query = """
            SELECT
                kcu.CONSTRAINT_NAME,
                kcu.COLUMN_NAME,
                kcu.REFERENCED_TABLE_NAME,
                kcu.REFERENCED_COLUMN_NAME,
                rc.DELETE_RULE,
                rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
            WHERE kcu.TABLE_SCHEMA = '\(dbSafe)'
                AND kcu.TABLE_NAME = '\(safe)'
                AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION
            """
        let raw = try await actor.execute(query)

        return raw.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[0],
                  let column = row[1],
                  let refTable = row[2],
                  let refColumn = row[3] else { return nil }
            return ForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: row[4] ?? "NO ACTION",
                onUpdate: row[5] ?? "NO ACTION"
            )
        }
    }

    func fetchDatabases() async throws -> [String] {
        let raw = try await actor.execute("SHOW DATABASES")
        return raw.rows.compactMap { $0.first ?? nil }
    }

    func switchDatabase(to name: String) async throws {
        let safe = name.replacingOccurrences(of: "`", with: "``")
        _ = try await actor.execute("USE `\(safe)`")
    }

    func switchSchema(to name: String) async throws {
        throw MySQLError.unsupported("MySQL does not support schemas")
    }

    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        _ = try await actor.execute("START TRANSACTION")
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }
}

// MARK: - MySQL Actor (thread-safe C API access)

private actor MySQLActor {
    private var mysql: UnsafeMutablePointer<MYSQL>?

    func connect(host: String, port: Int, user: String, password: String, database: String, sslEnabled: Bool) throws {
        // Close existing connection if reconnecting
        if let mysql { mysql_close(mysql); self.mysql = nil }

        guard let handle = mysql_init(nil) else {
            throw MySQLError.connectionFailed("Failed to initialize MySQL client")
        }

        mysql_options(handle, MYSQL_SET_CHARSET_NAME, "utf8mb4")

        var timeout: UInt32 = 10
        mysql_options(handle, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        var readTimeout: UInt32 = 30
        mysql_options(handle, MYSQL_OPT_READ_TIMEOUT, &readTimeout)
        var writeTimeout: UInt32 = 30
        mysql_options(handle, MYSQL_OPT_WRITE_TIMEOUT, &writeTimeout)

        var reconnect: my_bool = 0
        mysql_options(handle, MYSQL_OPT_RECONNECT, &reconnect)

        if sslEnabled {
            var sslEnforce: my_bool = 1
            mysql_options(handle, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
            var sslVerify: my_bool = 0
            mysql_options(handle, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)
        } else {
            var sslEnforce: my_bool = 0
            mysql_options(handle, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
            var sslVerify: my_bool = 0
            mysql_options(handle, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)
        }

        guard mysql_real_connect(
            handle, host, user, password, database, UInt32(port), nil, 0
        ) != nil else {
            let msg = String(cString: mysql_error(handle))
            mysql_close(handle)
            throw MySQLError.connectionFailed(msg)
        }

        self.mysql = handle
    }

    func close() {
        if let mysql {
            mysql_close(mysql)
            self.mysql = nil
        }
    }

    func ping() throws -> Bool {
        guard let mysql else { throw MySQLError.notConnected }
        if mysql_ping(mysql) != 0 {
            throw MySQLError.queryFailed(String(cString: mysql_error(mysql)))
        }
        return true
    }

    func serverVersion() -> String? {
        guard let mysql else { return nil }
        return String(cString: mysql_get_server_info(mysql))
    }

    func execute(_ query: String) throws -> RawMySQLResult {
        guard let mysql else { throw MySQLError.notConnected }

        let start = Date()

        guard mysql_real_query(mysql, query, UInt(query.utf8.count)) == 0 else {
            throw MySQLError.queryFailed(String(cString: mysql_error(mysql)))
        }

        guard let result = mysql_store_result(mysql) else {
            if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(String(cString: mysql_error(mysql)))
            }
            let affected = Int(mysql_affected_rows(mysql))
            return RawMySQLResult(
                columns: [], columnTypes: [], rows: [],
                rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false
            )
        }
        defer { mysql_free_result(result) }

        let fieldCount = Int(mysql_num_fields(result))
        var columns: [String] = []
        var columnTypes: [String] = []

        if let fields = mysql_fetch_fields(result) {
            for i in 0..<fieldCount {
                let field = fields[i]
                columns.append(String(cString: field.name))
                columnTypes.append(mysqlFieldTypeName(field.type.rawValue))
            }
        }

        var rows: [[String?]] = []
        let maxRows = 100_000

        while let row = mysql_fetch_row(result) {
            if rows.count >= maxRows {
                break
            }

            let lengths = mysql_fetch_lengths(result)
            var rowData: [String?] = []
            for i in 0..<fieldCount {
                if let value = row[i] {
                    let len = Int(lengths?[i] ?? 0)
                    let data = Data(bytes: value, count: len)
                    rowData.append(String(data: data, encoding: .utf8) ?? String(cString: value))
                } else {
                    rowData.append(nil)
                }
            }
            rows.append(rowData)
        }

        let isTruncated = rows.count >= maxRows
        let affected = columns.isEmpty ? Int(mysql_affected_rows(mysql)) : 0
        return RawMySQLResult(
            columns: columns, columnTypes: columnTypes, rows: rows,
            rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: isTruncated
        )
    }
}

// MARK: - MySQL Field Type Names

nonisolated private func mysqlFieldTypeName(_ typeValue: UInt32) -> String {
    switch typeValue {
    case 0: return "DECIMAL"
    case 1: return "TINYINT"
    case 2: return "SMALLINT"
    case 3: return "INT"
    case 4: return "FLOAT"
    case 5: return "DOUBLE"
    case 6: return "NULL"
    case 7: return "TIMESTAMP"
    case 8: return "BIGINT"
    case 9: return "MEDIUMINT"
    case 10: return "DATE"
    case 11: return "TIME"
    case 12: return "DATETIME"
    case 13: return "YEAR"
    case 15: return "VARCHAR"
    case 16: return "BIT"
    case 245: return "JSON"
    case 246: return "NEWDECIMAL"
    case 249: return "TINYTEXT"
    case 250: return "MEDIUMTEXT"
    case 251: return "LONGTEXT"
    case 252: return "TEXT"
    case 253: return "VARCHAR"
    case 254: return "CHAR"
    case 255: return "GEOMETRY"
    default: return "UNKNOWN"
    }
}

private struct RawMySQLResult: Sendable {
    let columns: [String]
    let columnTypes: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

enum MySQLError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "MySQL connection failed: \(msg)"
        case .notConnected: return "Not connected to MySQL database"
        case .queryFailed(let msg): return "MySQL query failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
