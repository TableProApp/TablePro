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
        ExplainVariant(
            id: "explain", label: "Explain", sqlPrefix: "EXPLAIN QUERY PLAN", format: .sqliteQueryPlan
        )
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
    static let fileExtensions: [String] = ["db", "db3", "s3db", "sl3", "sqlite", "sqlite3", "sqlitedb"]
    static let brandColorHex = "#003B57"
    static let supportsDatabaseSwitching = false
    static let supportsTriggers = true
    static let supportsDatabaseTriggerBrowse = true
    static let supportsTriggerEditing = true
    static let structureColumnFields: [StructureColumnField] =
        [.name, .type, .nullable, .defaultValue, .generated, .generationExpression, .autoIncrement]

    static let supportsCheckConstraints = true

    /// ALTER TABLE ... ADD/DROP CONSTRAINT arrived in SQLite 3.53.0 (2026-04-09). The plugin links
    /// the system libsqlite3, so this tracks the user's macOS rather than the app version, and it
    /// is a per-process constant because one dylib is linked for the process's whole lifetime.
    static let supportsCheckConstraintEditing = sqlite3_libversion_number() >= 3_053_000

    static let supportsGeneratedColumns = true
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
        paginationStyle: .limit,
        caseSensitivityStyle: .collationDefined
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        SQLitePluginDriver(config: config)
    }
}

// MARK: - Busy Wait

/// Ends a wait on a locked database when the user presses Stop, and after the configured timeout.
///
/// `sqlite3_busy_timeout` cannot do the first of those: it sleeps inside SQLite with nothing to
/// interrupt it, and `sqlite3_interrupt` does not reach a connection that is waiting for a lock
/// rather than running a statement. Measured against SQLite 3.54.0 with a second connection
/// holding `BEGIN EXCLUSIVE`: the interrupt was ignored and the waiter ran the full 60 seconds
/// before returning `SQLITE_BUSY`. A busy handler is the documented way to keep that decision,
/// because it is called back on every retry and stops the wait by returning zero.
///
/// Read and written from whichever thread is stepping a statement and from the caller of Stop, so
/// every access takes the lock.
private final class SQLiteBusyState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var timeoutMilliseconds: Int32 = 0

    /// How long one retry waits. Also the granularity at which Stop is noticed.
    static let retryIntervalMilliseconds: Int32 = 10

    func setTimeout(milliseconds: Int32) {
        lock.lock()
        defer { lock.unlock() }
        timeoutMilliseconds = milliseconds
    }

    func beginOperation() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = false
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
    }

    /// - Parameter retryCount: How many times SQLite has already called back for this lock.
    /// - Returns: `true` to wait and retry, `false` to give up and let the step return `SQLITE_BUSY`.
    func shouldRetry(afterRetryCount retryCount: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        guard timeoutMilliseconds > 0 else { return true }
        return retryCount * Self.retryIntervalMilliseconds < timeoutMilliseconds
    }
}

private let sqliteBusyHandler: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { context, retryCount in
    guard let context else { return 0 }
    let state = Unmanaged<SQLiteBusyState>.fromOpaque(context).takeUnretainedValue()
    guard state.shouldRetry(afterRetryCount: retryCount) else { return 0 }
    usleep(UInt32(SQLiteBusyState.retryIntervalMilliseconds) * 1_000)
    return 1
}

// MARK: - SQLite Connection Actor

private actor SQLiteConnectionActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteConnectionActor")

    private var db: OpaquePointer?
    private let busyState: SQLiteBusyState

    init(busyState: SQLiteBusyState) {
        self.busyState = busyState
    }

    var isConnected: Bool { db != nil }

    func open(path: String) throws {
        let result = sqlite3_open(path, &db)

        if result != SQLITE_OK {
            let errorMessage = db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unknown SQLite error"
            throw SQLitePluginError.connectionFailed(errorMessage)
        }
        installBusyHandler()
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func applyBusyTimeout(_ milliseconds: Int32) {
        busyState.setTimeout(milliseconds: milliseconds)
    }

    func beginBusyOperation() {
        busyState.beginOperation()
    }

    private func installBusyHandler() {
        guard let db else { return }
        sqlite3_busy_handler(db, sqliteBusyHandler, Unmanaged.passUnretained(busyState).toOpaque())
    }

    var dbHandleForInterrupt: Int { db.map { Int(bitPattern: $0) } ?? 0 }

    func executeQuery(_ query: String) throws -> SQLiteRawResult {
        guard let db else {
            throw SQLitePluginError.notConnected
        }
        busyState.beginOperation()

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

        var rows: [[PluginCellValue]] = []
        var rowsAffected = 0
        var truncated = false

        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }

            var row: [PluginCellValue] = []

            for i in 0..<columnCount {
                let colType = sqlite3_column_type(statement, i)
                if colType == SQLITE_NULL {
                    row.append(.null)
                } else if colType == SQLITE_BLOB {
                    let byteCount = Int(sqlite3_column_bytes(statement, i))
                    if byteCount > 0, let blobPtr = sqlite3_column_blob(statement, i) {
                        row.append(.bytes(Data(bytes: blobPtr, count: byteCount)))
                    } else {
                        row.append(.bytes(Data()))
                    }
                } else if let text = sqlite3_column_text(statement, i) {
                    row.append(.text(String(cString: text)))
                } else {
                    row.append(.null)
                }
            }

            rows.append(row)
            stepResult = sqlite3_step(statement)
        }

        if !truncated, stepResult != SQLITE_DONE {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
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
        busyState.beginOperation()
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

        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if Task.isCancelled {
                if !batch.isEmpty {
                    continuation.yield(.rows(batch))
                }
                sqlite3_finalize(statement)
                continuation.finish(throwing: CancellationError())
                return
            }

            var row: [PluginCellValue] = []

            for i in 0..<columnCount {
                let colType = sqlite3_column_type(statement, i)
                if colType == SQLITE_NULL {
                    row.append(.null)
                } else if colType == SQLITE_BLOB {
                    let byteCount = Int(sqlite3_column_bytes(statement, i))
                    if byteCount > 0, let blobPtr = sqlite3_column_blob(statement, i) {
                        row.append(.bytes(Data(bytes: blobPtr, count: byteCount)))
                    } else {
                        row.append(.bytes(Data()))
                    }
                } else if let text = sqlite3_column_text(statement, i) {
                    row.append(.text(String(cString: text)))
                } else {
                    row.append(.null)
                }
            }

            batch.append(row)
            if batch.count >= batchSize {
                continuation.yield(.rows(batch))
                batch.removeAll(keepingCapacity: true)
            }
            stepResult = sqlite3_step(statement)
        }

        if !batch.isEmpty {
            continuation.yield(.rows(batch))
        }

        // A step that ends on anything but `SQLITE_DONE` stopped early: a locked database, an I/O
        // error on the volume, a corrupt page. Finishing the stream normally would report the rows
        // read so far as the whole table, which is indistinguishable from an empty one.
        guard stepResult == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            continuation.finish(throwing: SQLitePluginError.queryFailed(message))
            return
        }

        sqlite3_finalize(statement)
        continuation.finish()
    }

    func executeParameterizedQuery(_ query: String, parameters: [PluginCellValue]) throws -> SQLiteRawResult {
        guard let db else {
            throw SQLitePluginError.notConnected
        }
        busyState.beginOperation()

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

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            let bindResult: Int32

            switch param {
            case .null:
                bindResult = sqlite3_bind_null(statement, bindIndex)
            case .text(let stringValue):
                bindResult = sqlite3_bind_text(statement, bindIndex, stringValue, -1, sqliteTransient)
            case .bytes(let data):
                bindResult = data.withUnsafeBytes { rawBuffer -> Int32 in
                    let baseAddress = rawBuffer.baseAddress
                    return sqlite3_bind_blob(statement, bindIndex, baseAddress, Int32(data.count), sqliteTransient)
                }
            }

            if bindResult != SQLITE_OK {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                throw SQLitePluginError.queryFailed(
                    "Failed to bind parameter \(index): \(errorMessage)"
                )
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

        var rows: [[PluginCellValue]] = []
        var rowsAffected = 0
        var truncated = false

        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }

            var row: [PluginCellValue] = []

            for i in 0..<columnCount {
                let colType = sqlite3_column_type(statement, i)
                if colType == SQLITE_NULL {
                    row.append(.null)
                } else if colType == SQLITE_BLOB {
                    let byteCount = Int(sqlite3_column_bytes(statement, i))
                    if byteCount > 0, let blobPtr = sqlite3_column_blob(statement, i) {
                        row.append(.bytes(Data(bytes: blobPtr, count: byteCount)))
                    } else {
                        row.append(.bytes(Data()))
                    }
                } else if let text = sqlite3_column_text(statement, i) {
                    row.append(.text(String(cString: text)))
                } else {
                    row.append(.null)
                }
            }

            rows.append(row)
            stepResult = sqlite3_step(statement)
        }

        if !truncated, stepResult != SQLITE_DONE {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
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
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - SQLite Plugin Driver

final class SQLitePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let busyState = SQLiteBusyState()
    private let connectionActor: SQLiteConnectionActor
    private let interruptLock = NSLock()
    nonisolated(unsafe) private var _dbHandleForInterrupt: OpaquePointer?

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLitePluginDriver")

    var currentSchema: String? { nil }
    var serverVersion: String? { String(cString: sqlite3_libversion()) }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .foreignKeyToggle,
            .truncateTable,
            .cancelQuery,
            .batchExecute,
            .schemaCompare,
            .dataCompare,
        ]
    }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self.connectionActor = SQLiteConnectionActor(busyState: busyState)
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
        await connectionActor.applyBusyTimeout(Int32(max(0, seconds) * 1_000))
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

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executeParameterizedQuery(query, parameters: parameters)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    /// `sqlite3_interrupt` ends a statement that is running. A connection waiting for a lock is
    /// not running one, and measurably ignores it, so the busy handler is what ends that wait.
    func cancelQuery() throws {
        busyState.cancel()
        interruptLock.lock()
        defer { interruptLock.unlock() }
        guard let db = _dbHandleForInterrupt else { return }
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

    // MARK: - User Query

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        guard Self.returnsRows(query) else { return nil }
        return try await boundedQueryFromStream(query: query, rowCap: rowCap)
    }

    /// A capped read from a caller that resolves its own cap, the MCP bridge among them, still
    /// streams. Routing every uncapped statement through the stream is what made a DML statement
    /// report no row count, because a stepped statement carries its `sqlite3_changes` nowhere.
    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        if parameters == nil, let cap = rowCap, cap > 0,
           let bounded = try await executeBoundedQuery(query: query, rowCap: cap) {
            return bounded
        }

        let raw: PluginQueryResult
        if let parameters {
            raw = try await executeParameterized(query: query, parameters: parameters)
        } else {
            raw = try await execute(query: query)
        }
        guard let cap = rowCap, cap > 0, raw.rows.count > cap else { return raw }
        return PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: Array(raw.rows.prefix(cap)),
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: true,
            statusMessage: raw.statusMessage
        )
    }

    private static let rowReturningKeywords: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE", "PRAGMA", "EXPLAIN"]

    private static func returnsRows(_ query: String) -> Bool {
        var remaining = Substring(query).drop { $0.isWhitespace }
        while remaining.first == "(" {
            remaining = remaining.dropFirst().drop { $0.isWhitespace }
        }
        let keyword = remaining.prefix { $0.isLetter }.uppercased()
        return rowReturningKeywords.contains(keyword)
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
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeString = row[safe: 1]?.asText ?? "table"
            let tableType = typeString.lowercased() == "view" ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeTable = escapeStringLiteral(table)
        // table_xinfo rather than table_info: table_info omits generated columns entirely, so they
        // were invisible to the structure editor and to every write path that reads this list.
        let query = "PRAGMA table_xinfo('\(safeTable)')"
        let result = try await execute(query: query)
        let generationExpressions = SQLiteCheckConstraintParser.generationExpressions(
            inCreateStatement: try await createStatement(forTable: table) ?? ""
        )

        return result.rows.compactMap { row in
            guard row.count >= 7,
                  let name = row[1].asText,
                  let dataType = row[2].asText else {
                return nil
            }

            // hidden: 0 normal, 1 a virtual table's hidden column, 2 VIRTUAL generated,
            // 3 STORED generated.
            let hidden = row[6].asText.flatMap { Int($0) } ?? 0
            guard hidden != 1 else { return nil }

            let isNullable = row[3].asText == "0"
            // PRAGMA pk column: 0 = not PK, 1+ = position in composite PK
            let pkText = row[5].asText
            let isPrimaryKey = pkText != nil && pkText != "0"
            let defaultValue = row[4].asText
            let generationKind: GenerationKind? = hidden == 2 ? .virtual : (hidden == 3 ? .stored : nil)

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                isGenerated: generationKind != nil,
                generationExpression: generationKind == nil ? nil : generationExpressions[name],
                generationKind: generationKind
            )
        }
    }

    private func createStatement(forTable table: String) async throws -> String? {
        let query = "SELECT sql FROM sqlite_master WHERE type='table' AND name='\(escapeStringLiteral(table))'"
        let result = try await execute(query: query)
        return result.rows.first?[safe: 0]?.asText
    }

    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        guard let statement = try await createStatement(forTable: table) else { return [] }
        return SQLiteCheckConstraintParser.constraints(inCreateStatement: statement).map { parsed in
            PluginCheckConstraintInfo(name: parsed.name, expression: parsed.expression)
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
                  let tableName = row[0].asText,
                  let columnName = row[2].asText,
                  let dataType = row[3].asText else {
                continue
            }

            let isNullable = row[4].asText == "0"
            let defaultValue = row[5].asText
            // PRAGMA table_info pk column: 0 = not PK, 1+ = position in composite PK
            let pkText = row[6].asText
            let isPrimaryKey = pkText != nil && pkText != "0"

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

    var providesBulkForeignKeyFetch: Bool { true }

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
                  let tableName = row[0].asText,
                  let id = row[1].asText,
                  let refTable = row[2].asText,
                  let fromCol = row[3].asText,
                  let toCol = row[4].asText else {
                continue
            }

            let onUpdate = row[5].asText ?? "NO ACTION"
            let onDelete = row[6].asText ?? "NO ACTION"

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
                  let indexName = row[0].asText else { continue }

            let isUnique = row[1].asText == "1"
            let origin = row[2].asText ?? "c"

            if let idx = indexLookup[indexName] {
                if let colName = row[3].asText {
                    indexMap[idx].columns.append(colName)
                }
            } else {
                let columns: [String] = row[3].asText.map { [$0] } ?? []
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

        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard row.count >= 5,
                  let refTable = row[2].asText,
                  let fromCol = row[3].asText,
                  let toCol = row[4].asText else {
                return nil
            }

            let id = row[0].asText ?? "0"
            let onUpdate = row.count >= 6 ? (row[5].asText ?? "NO ACTION") : "NO ACTION"
            let onDelete = row.count >= 7 ? (row[6].asText ?? "NO ACTION") : "NO ACTION"

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

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await sqliteTriggerList(table: table)
    }

    var supportsTransactionalDDL: Bool { true }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        """
        CREATE TRIGGER \(quoteIdentifier("trigger_name"))
        AFTER INSERT ON \(quoteIdentifier(table))
        BEGIN
            -- INSERT INTO audit ...;
        END;
        """
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        "DROP TRIGGER IF EXISTS \(quoteIdentifier(name))"
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeStringLiteral(table)
        let query = """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND name = '\(safeTable)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0].asText else {
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
              let ddl = firstRow[0].asText else {
            throw SQLitePluginError.queryFailed("Failed to fetch definition for view '\(view)'")
        }

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let safeTableName = table.replacingOccurrences(of: "\"", with: "\"\"")
        let countQuery = "SELECT COUNT(*) FROM (SELECT 1 FROM \"\(safeTableName)\" LIMIT 100001)"
        let countResult = try await execute(query: countQuery)
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let firstCell = row.first else { return nil }
            return Int64(firstCell.asText ?? "0")
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
        if let expression = col.generationExpression?.nilIfEmpty {
            def += " GENERATED ALWAYS AS (\(expression)) \((col.generationKind ?? .virtual).rawValue)"
            if !col.isNullable { def += " NOT NULL" }
            return def
        }
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

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        let colDef = sqliteColumnDefinition(addableColumn(column), inlinePK: false)
        return "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(colDef)"
    }

    /// ALTER TABLE ADD COLUMN refuses a STORED generated column outright once the table holds rows
    /// ("cannot add a STORED column"), so the ALTER path downgrades to VIRTUAL. CREATE TABLE has no
    /// such limit and keeps whichever kind was chosen.
    private func addableColumn(_ column: PluginColumnDefinition) -> PluginColumnDefinition {
        guard column.generationKind == .stored else { return column }
        return PluginColumnDefinition(
            name: column.name,
            dataType: column.dataType,
            isNullable: column.isNullable,
            defaultValue: column.defaultValue,
            isPrimaryKey: column.isPrimaryKey,
            autoIncrement: column.autoIncrement,
            comment: column.comment,
            unsigned: column.unsigned,
            onUpdate: column.onUpdate,
            charset: column.charset,
            collation: column.collation,
            generationExpression: column.generationExpression,
            generationKind: .virtual
        )
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        guard oldColumn.name != newColumn.name else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    /// ADD/DROP CONSTRAINT arrived in SQLite 3.53.0. Returning nil below that version makes
    /// `SchemaStatementGenerator` refuse the change with "Unsupported schema operation" rather than
    /// sending a statement the linked library cannot parse.
    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        guard SQLitePlugin.supportsCheckConstraintEditing else { return nil }
        let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !constraint.name.isEmpty else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) ADD CONSTRAINT "
            + "\(quoteIdentifier(constraint.name)) CHECK (\(expression))"
    }

    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        guard SQLitePlugin.supportsCheckConstraintEditing, !constraintName.isEmpty else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(quoteIdentifier(table)) (\(cols))"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(indexName))"
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
