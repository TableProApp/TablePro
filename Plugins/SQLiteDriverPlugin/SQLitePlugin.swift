//
//  SQLitePlugin.swift
//  TablePro
//

import Foundation
import os
import SQLite3
import TableProPluginKit

final class SQLitePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "SQLite Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "SQLite file-based database support"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "Explain", sqlPrefix: "EXPLAIN QUERY PLAN")
    ]

    static let databaseTypeId = "SQLite"
    static let databaseDisplayName = "SQLite"
    static let iconName = "sqlite-icon"
    static let defaultPort = 0

    // MARK: - UI/Capability Metadata

    static let requiresAuthentication = false
    static let supportsSSH = false
    static let supportsSSL = false
    static let isDownloadable = false
    static let pathFieldRole: PathFieldRole = .filePath
    static let connectionMode: ConnectionMode = .fileBased
    static let urlSchemes: [String] = ["sqlite"]
    static let fileExtensions: [String] = ["db", "sqlite", "sqlite3"]
    static let brandColorHex = "#003B57"
    static let supportsDatabaseSwitching = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INTEGER", "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT"],
        "Float": ["REAL", "DOUBLE", "FLOAT", "NUMERIC", "DECIMAL"],
        "String": ["TEXT", "VARCHAR", "CHARACTER", "CHAR", "CLOB", "NVARCHAR", "NCHAR"],
        "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
        "Binary": ["BLOB"],
        "Boolean": ["BOOLEAN"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
            "ON", "AND", "OR", "NOT", "IN", "LIKE", "GLOB", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "TRIGGER",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "IFNULL", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT",
            "AUTOINCREMENT", "WITHOUT", "ROWID", "PRAGMA",
            "REPLACE", "ABORT", "FAIL", "IGNORE", "ROLLBACK",
            "TEMP", "TEMPORARY", "VACUUM", "EXPLAIN", "QUERY", "PLAN"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT", "TOTAL",
            "LENGTH", "SUBSTR", "SUBSTRING", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
            "REPLACE", "INSTR", "PRINTF",
            "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME",
            "ABS", "ROUND", "RANDOM",
            "CAST", "TYPEOF",
            "COALESCE", "IFNULL", "NULLIF", "HEX", "QUOTE"
        ],
        dataTypes: [
            "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC",
            "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
            "UNSIGNED", "BIG", "INT2", "INT8",
            "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NATIVE",
            "NVARCHAR", "CLOB",
            "DOUBLE", "PRECISION", "FLOAT",
            "DECIMAL", "BOOLEAN", "DATE", "DATETIME"
        ],
        tableOptions: [
            "WITHOUT ROWID", "STRICT"
        ],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        SQLitePluginDriver(config: config)
    }
}

// MARK: - SQLite Connection Actor

private actor SQLiteConnectionActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteConnectionActor")

    private var db: OpaquePointer?

    var isConnected: Bool { db != nil }

    func open(path: String) throws {
        let result = sqlite3_open(path, &db)

        if result != SQLITE_OK {
            let errorMessage = db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unknown SQLite error"
            throw SQLitePluginError.connectionFailed(errorMessage)
        }
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func applyBusyTimeout(_ milliseconds: Int32) {
        guard let db else { return }
        sqlite3_busy_timeout(db, milliseconds)
    }

    var dbHandleForInterrupt: Int { db.map { Int(bitPattern: $0) } ?? 0 }

    func executeQuery(_ query: String) throws -> SQLiteRawResult {
        guard let db else {
            throw SQLitePluginError.notConnected
        }

        let startTime = Date()
        var statement: OpaquePointer?

        let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)

        if prepareResult != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw SQLitePluginError.queryFailed(errorMessage)
        }

        defer {
            sqlite3_finalize(statement)
        }

        let columnCount = sqlite3_column_count(statement)
        var columns: [String] = []
        var columnTypeNames: [String] = []

        for i in 0..<columnCount {
            if let name = sqlite3_column_name(statement, i) {
                columns.append(String(cString: name))
            } else {
                columns.append("column_\(i)")
            }

            if let typePtr = sqlite3_column_decltype(statement, i) {
                columnTypeNames.append(String(cString: typePtr))
            } else {
                columnTypeNames.append("")
            }
        }

        var rows: [[String?]] = []
        var rowsAffected = 0
        var truncated = false

        while sqlite3_step(statement) == SQLITE_ROW {
            if rows.count >= PluginRowLimits.defaultMax {
                truncated = true
                break
            }

            var row: [String?] = []

            for i in 0..<columnCount {
                let colType = sqlite3_column_type(statement, i)
                if colType == SQLITE_NULL {
                    row.append(nil)
                } else if colType == SQLITE_BLOB {
                    let byteCount = Int(sqlite3_column_bytes(statement, i))
                    if byteCount > 0, let blobPtr = sqlite3_column_blob(statement, i) {
                        let data = Data(bytes: blobPtr, count: byteCount)
                        row.append(String(data: data, encoding: .isoLatin1) ?? "")
                    } else {
                        row.append("")
                    }
                } else if let text = sqlite3_column_text(statement, i) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }

            rows.append(row)
        }

        if columns.isEmpty {
            rowsAffected = Int(sqlite3_changes(db))
        }

        let executionTime = Date().timeIntervalSince(startTime)

        return SQLiteRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: executionTime,
            isTruncated: truncated
        )
    }

    func streamQuery(_ query: String, continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation) throws {
        guard let db else {
            throw SQLitePluginError.notConnected
        }

        var statement: OpaquePointer?

        let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw SQLitePluginError.queryFailed(errorMessage)
        }

        let columnCount = sqlite3_column_count(statement)
        var columns: [String] = []
        var columnTypeNames: [String] = []

        for i in 0..<columnCount {
            if let name = sqlite3_column_name(statement, i) {
                columns.append(String(cString: name))
            } else {
                columns.append("column_\(i)")
            }

            if let typePtr = sqlite3_column_decltype(statement, i) {
                columnTypeNames.append(String(cString: typePtr))
            } else {
                columnTypeNames.append("")
            }
        }

        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columnTypeNames,
            estimatedRowCount: nil
        )))

        let batchSize = 5_000
        var batch: [PluginRow] = []
        batch.reserveCapacity(batchSize)

        while sqlite3_step(statement) == SQLITE_ROW {
            if Task.isCancelled {
                if !batch.isEmpty {
                    continuation.yield(.rows(batch))
                }
                sqlite3_finalize(statement)
                continuation.finish(throwing: CancellationError())
                return
            }

            var row: [String?] = []

            for i in 0..<columnCount {
                let colType = sqlite3_column_type(statement, i)
                if colType == SQLITE_NULL {
                    row.append(nil)
                } else if colType == SQLITE_BLOB {
                    let byteCount = Int(sqlite3_column_bytes(statement, i))
                    if byteCount > 0, let blobPtr = sqlite3_column_blob(statement, i) {
                        let data = Data(bytes: blobPtr, count: byteCount)
                        row.append(String(data: data, encoding: .isoLatin1) ?? "")
                    } else {
                        row.append("")
                    }
                } else if let text = sqlite3_column_text(statement, i) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }

            batch.append(row)
            if batch.count >= batchSize {
                continuation.yield(.rows(batch))
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            continuation.yield(.rows(batch))
        }

        sqlite3_finalize(statement)
        continuation.finish()
    }

    func executeParameterizedQuery(_ query: String, stringParams: [String?]) throws -> SQLiteRawResult {
        guard let db else {
            throw SQLitePluginError.notConnected
        }

        let startTime = Date()
        var statement: OpaquePointer?

        let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)

        if prepareResult != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw SQLitePluginError.queryFailed(errorMessage)
        }

        defer {
            sqlite3_finalize(statement)
        }

        for (index, param) in stringParams.enumerated() {
            let bindIndex = Int32(index + 1)

            if let stringValue = param {
                // SQLITE_TRANSIENT ensures SQLite copies the string immediately,
                // preventing use-after-free from Swift's temporary C string bridge
                let bindResult = sqlite3_bind_text(
                    statement, bindIndex, stringValue, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
                if bindResult != SQLITE_OK {
                    let errorMessage = String(cString: sqlite3_errmsg(db))
                    throw SQLitePluginError.queryFailed(
                        "Failed to bind parameter \(index): \(errorMessage)"
                    )
                }
            } else {
                let bindResult = sqlite3_bind_null(statement, bindIndex)
                if bindResult != SQLITE_OK {
                    let errorMessage = String(cString: sqlite3_errmsg(db))
                    throw SQLitePluginError.queryFailed(
                        "Failed to bind NULL parameter \(index): \(errorMessage)"
                    )
                }
            }
        }

        let columnCount = sqlite3_column_count(statement)
        var columns: [String] = []
        var columnTypeNames: [String] = []

        for i in 0..<columnCount {
            if let name = sqlite3_column_name(statement, i) {
                columns.append(String(cString: name))
            } else {
                columns.append("column_\(i)")
            }

            if let typePtr = sqlite3_column_decltype(statement, i) {
                columnTypeNames.append(String(cString: typePtr))
            } else {
                columnTypeNames.append("")
            }
        }

        var rows: [[String?]] = []
        var rowsAffected = 0
        var truncated = false

        while sqlite3_step(statement) == SQLITE_ROW {
            if rows.count >= PluginRowLimits.defaultMax {
                truncated = true
                break
            }

            var row: [String?] = []

            for i in 0..<columnCount {
                let colType = sqlite3_column_type(statement, i)
                if colType == SQLITE_NULL {
                    row.append(nil)
                } else if colType == SQLITE_BLOB {
                    let byteCount = Int(sqlite3_column_bytes(statement, i))
                    if byteCount > 0, let blobPtr = sqlite3_column_blob(statement, i) {
                        let data = Data(bytes: blobPtr, count: byteCount)
                        row.append(String(data: data, encoding: .isoLatin1) ?? "")
                    } else {
                        row.append("")
                    }
                } else if let text = sqlite3_column_text(statement, i) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }

            rows.append(row)
        }

        if columns.isEmpty {
            rowsAffected = Int(sqlite3_changes(db))
        }

        let executionTime = Date().timeIntervalSince(startTime)

        return SQLiteRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: executionTime,
            isTruncated: truncated
        )
    }
}

private struct SQLiteRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - SQLite Plugin Driver

final class SQLitePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let connectionActor = SQLiteConnectionActor()
    private let interruptLock = NSLock()
    nonisolated(unsafe) private var _dbHandleForInterrupt: OpaquePointer?

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLitePluginDriver")
    private static let limitRegex = try? NSRegularExpression(pattern: "(?i)\\s+LIMIT\\s+\\d+")
    private static let offsetRegex = try? NSRegularExpression(pattern: "(?i)\\s+OFFSET\\s+\\d+")

    var currentSchema: String? { nil }
    var serverVersion: String? { String(cString: sqlite3_libversion()) }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection

    func connect() async throws {
        let path = expandPath(config.database)

        if !FileManager.default.fileExists(atPath: path) {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        try await connectionActor.open(path: path)
        let rawHandle = await connectionActor.dbHandleForInterrupt
        setInterruptHandle(rawHandle != 0 ? OpaquePointer(bitPattern: rawHandle) : nil)
    }

    func disconnect() {
        interruptLock.lock()
        _dbHandleForInterrupt = nil
        interruptLock.unlock()
        let actor = connectionActor
        Task { await actor.close() }
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        await connectionActor.applyBusyTimeout(Int32(seconds * 1_000))
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executeQuery(query)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executeParameterizedQuery(query, stringParams: parameters)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func cancelQuery() throws {
        interruptLock.lock()
        let db = _dbHandleForInterrupt
        interruptLock.unlock()
        guard let db else { return }
        sqlite3_interrupt(db)
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN QUERY PLAN \(sql)"
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String]? {
        ["VACUUM", "ANALYZE", "REINDEX", "Integrity Check"]
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        switch operation {
        case "VACUUM": return ["VACUUM"]
        case "ANALYZE": return table.map { ["ANALYZE \(quoteIdentifier($0))"] } ?? ["ANALYZE"]
        case "REINDEX": return table.map { ["REINDEX \(quoteIdentifier($0))"] } ?? ["REINDEX"]
        case "Integrity Check": return ["PRAGMA integrity_check"]
        default: return nil
        }
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE VIEW IF NOT EXISTS view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "DROP VIEW IF EXISTS \(quoted);\nCREATE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - Foreign Key Checks

    func foreignKeyDisableStatements() -> [String]? {
        ["PRAGMA foreign_keys = OFF"]
    }

    func foreignKeyEnableStatements() -> [String]? {
        ["PRAGMA foreign_keys = ON"]
    }

    // MARK: - Pagination

    func fetchRowCount(query: String) async throws -> Int {
        let baseQuery = stripLimitOffset(from: query)
        let countQuery = "SELECT COUNT(*) FROM (\(baseQuery))"
        let result = try await execute(query: countQuery)
        guard let firstRow = result.rows.first, let countStr = firstRow.first else { return 0 }
        return Int(countStr ?? "0") ?? 0
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let baseQuery = stripLimitOffset(from: query)
        let paginatedQuery = "\(baseQuery) LIMIT \(limit) OFFSET \(offset)"
        return try await execute(query: paginatedQuery)
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let query = """
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view')
            AND name NOT LIKE 'sqlite_%'
            ORDER BY name
        """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let typeString = (row[safe: 1] ?? nil) ?? "table"
            let tableType = typeString.lowercased() == "view" ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeTable = escapeStringLiteral(table)
        let query = "PRAGMA table_info('\(safeTable)')"
        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[1],
                  let dataType = row[2] else {
                return nil
            }

            let isNullable = row[3] == "0"
            // PRAGMA table_info pk column: 0 = not PK, 1+ = position in composite PK
            let isPrimaryKey = row[5] != nil && row[5] != "0"
            let defaultValue = row[4]

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let query = """
            SELECT m.name AS tbl, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk
            FROM sqlite_master m, pragma_table_info(m.name) p
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
            ORDER BY m.name, p.cid
            """
        let result = try await execute(query: query)

        var allColumns: [String: [PluginColumnInfo]] = [:]

        for row in result.rows {
            guard row.count >= 7,
                  let tableName = row[0],
                  let columnName = row[2],
                  let dataType = row[3] else {
                continue
            }

            let isNullable = row[4] == "0"
            let defaultValue = row[5]
            // PRAGMA table_info pk column: 0 = not PK, 1+ = position in composite PK
            let isPrimaryKey = row[6] != nil && row[6] != "0"

            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let query = """
            SELECT m.name AS table_name, p.id, p."table" AS referenced_table,
                   p."from" AS column_name, p."to" AS referenced_column,
                   p.on_update, p.on_delete
            FROM sqlite_master m, pragma_foreign_key_list(m.name) p
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
            ORDER BY m.name, p.id, p.seq
            """
        let result = try await execute(query: query)

        var allForeignKeys: [String: [PluginForeignKeyInfo]] = [:]

        for row in result.rows {
            guard row.count >= 7,
                  let tableName = row[0],
                  let id = row[1],
                  let refTable = row[2],
                  let fromCol = row[3],
                  let toCol = row[4] else {
                continue
            }

            let onUpdate = row[5] ?? "NO ACTION"
            let onDelete = row[6] ?? "NO ACTION"

            let fk = PluginForeignKeyInfo(
                name: "fk_\(tableName)_\(id)",
                column: fromCol,
                referencedTable: refTable,
                referencedColumn: toCol,
                onDelete: onDelete,
                onUpdate: onUpdate
            )

            allForeignKeys[tableName, default: []].append(fk)
        }

        return allForeignKeys
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let safeTable = escapeStringLiteral(table)
        let query = """
            SELECT il.name, il."unique", il.origin, ii.name AS col_name
            FROM pragma_index_list('\(safeTable)') il
            LEFT JOIN pragma_index_info(il.name) ii ON 1=1
            ORDER BY il.seq, ii.seqno
            """
        let result = try await execute(query: query)

        var indexMap: [(name: String, isUnique: Bool, isPrimary: Bool, columns: [String])] = []
        var indexLookup: [String: Int] = [:]

        for row in result.rows {
            guard row.count >= 4,
                  let indexName = row[0] else { continue }

            let isUnique = row[1] == "1"
            let origin = row[2] ?? "c"

            if let idx = indexLookup[indexName] {
                if let colName = row[3] {
                    indexMap[idx].columns.append(colName)
                }
            } else {
                let columns: [String] = row[3].map { [$0] } ?? []
                indexLookup[indexName] = indexMap.count
                indexMap.append((
                    name: indexName,
                    isUnique: isUnique,
                    isPrimary: origin == "pk",
                    columns: columns
                ))
            }
        }

        return indexMap.map { entry in
            PluginIndexInfo(
                name: entry.name,
                columns: entry.columns,
                isUnique: entry.isUnique,
                isPrimary: entry.isPrimary,
                type: "BTREE"
            )
        }.sorted { $0.isPrimary && !$1.isPrimary }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let safeTable = escapeStringLiteral(table)
        let query = "PRAGMA foreign_key_list('\(safeTable)')"
        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 5,
                  let refTable = row[2],
                  let fromCol = row[3],
                  let toCol = row[4] else {
                return nil
            }

            let id = row[0] ?? "0"
            let onUpdate = row.count >= 6 ? (row[5] ?? "NO ACTION") : "NO ACTION"
            let onDelete = row.count >= 7 ? (row[6] ?? "NO ACTION") : "NO ACTION"

            return PluginForeignKeyInfo(
                name: "fk_\(table)_\(id)",
                column: fromCol,
                referencedTable: refTable,
                referencedColumn: toCol,
                onDelete: onDelete,
                onUpdate: onUpdate
            )
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeStringLiteral(table)
        let query = """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND name = '\(safeTable)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0] else {
            throw SQLitePluginError.queryFailed("Failed to fetch DDL for table '\(table)'")
        }

        let formatted = formatDDL(ddl)
        return formatted.hasSuffix(";") ? formatted : formatted + ";"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let safeView = escapeStringLiteral(view)
        let query = """
            SELECT sql FROM sqlite_master
            WHERE type = 'view' AND name = '\(safeView)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0] else {
            throw SQLitePluginError.queryFailed("Failed to fetch definition for view '\(view)'")
        }

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let safeTableName = table.replacingOccurrences(of: "\"", with: "\"\"")
        let countQuery = "SELECT COUNT(*) FROM (SELECT 1 FROM \"\(safeTableName)\" LIMIT 100001)"
        let countResult = try await execute(query: countQuery)
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let countStr = row.first else { return nil }
            return Int64(countStr ?? "0")
        }()

        return PluginTableMetadata(
            tableName: table,
            rowCount: rowCount,
            engine: "SQLite"
        )
    }

    func fetchDatabases() async throws -> [String] {
        []
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        throw SQLitePluginError.unsupportedOperation
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            '' as schema,
            name,
            type as kind,
            '' as charset,
            '' as collation,
            '' as estimated_rows,
            '' as total_size,
            '' as data_size,
            '' as index_size,
            '' as comment
        FROM sqlite_master
        WHERE type IN ('table', 'view')
        AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
    }

    // MARK: - Private Helpers

    nonisolated private func setInterruptHandle(_ handle: OpaquePointer?) {
        interruptLock.lock()
        _dbHandleForInterrupt = handle
        interruptLock.unlock()
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryToRun = String(query)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                do {
                    try await self.connectionActor.streamQuery(queryToRun, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }

    private func stripLimitOffset(from query: String) -> String {
        var result = query

        if let limitRegex = Self.limitRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = limitRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        if let offsetRegex = Self.offsetRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = offsetRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let tableName = quoteIdentifier(definition.tableName)
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { sqliteColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(sqliteForeignKeyDefinition(fk))
        }

        let sql = "CREATE TABLE \(tableName) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        return sql
    }

    private func sqliteColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        var def = "\(quoteIdentifier(col.name)) \(col.dataType)"
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
            if col.autoIncrement {
                def += " AUTOINCREMENT"
            }
        }
        if !col.isNullable {
            def += " NOT NULL"
        }
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(sqliteDefaultValue(defaultValue))"
        }
        return def
    }

    private func sqliteDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_DATE" || upper == "CURRENT_TIME"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    private func sqliteForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        var def = "FOREIGN KEY (\(cols)) REFERENCES \(quoteIdentifier(fk.referencedTable)) (\(refCols))"
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    private func formatDDL(_ ddl: String) -> String {
        guard ddl.uppercased().hasPrefix("CREATE TABLE") else {
            return ddl
        }

        var formatted = ddl

        if let range = formatted.range(of: "(") {
            let before = String(formatted[..<range.lowerBound])
            let after = String(formatted[range.upperBound...])
            formatted = before + "(\n  " + after.trimmingCharacters(in: .whitespaces)
        }

        var result = ""
        var depth = 0
        var i = 0
        let chars = Array(formatted)

        while i < chars.count {
            let char = chars[i]

            if char == "(" {
                depth += 1
                result.append(char)
            } else if char == ")" {
                depth -= 1
                result.append(char)
            } else if char == "," && depth == 1 {
                result.append(",\n  ")
                i += 1
                while i < chars.count && chars[i].isWhitespace {
                    i += 1
                }
                i -= 1
            } else {
                result.append(char)
            }

            i += 1
        }

        formatted = result

        if let range = formatted.range(of: ")", options: .backwards) {
            let before = String(formatted[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(formatted[range.lowerBound...])
            formatted = before + "\n" + after
        }

        return formatted.isEmpty ? ddl : formatted
    }
}

// MARK: - Errors

enum SQLitePluginError: Error {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupportedOperation
}

extension SQLitePluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .queryFailed(let msg): return msg
        case .unsupportedOperation: return String(localized: "Operation not supported")
        }
    }
}
