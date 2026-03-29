//
//  MSSQLPlugin.swift
//  TablePro
//

import CFreeTDS
import Foundation
import os
import TableProPluginKit

final class MSSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "MSSQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Microsoft SQL Server support via FreeTDS db-lib"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SQL Server"
    static let databaseDisplayName = "SQL Server"
    static let iconName = "mssql-icon"
    static let defaultPort = 1433
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(id: "mssqlSchema", label: "Schema", placeholder: "dbo", defaultValue: "dbo")
    ]

    // MARK: - UI/Capability Metadata

    static let postConnectActions: [PostConnectAction] = [.selectDatabaseFromLastSession]
    static let brandColorHex = "#E34517"
    static let systemDatabaseNames: [String] = ["master", "tempdb", "model", "msdb"]
    static let defaultSchemaName = "dbo"
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INT", "BIGINT"],
        "Float": ["FLOAT", "REAL", "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY"],
        "String": ["CHAR", "VARCHAR", "TEXT", "NCHAR", "NVARCHAR", "NTEXT"],
        "Date": ["DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET"],
        "Binary": ["BINARY", "VARBINARY", "IMAGE"],
        "Boolean": ["BIT"],
        "XML": ["XML"],
        "UUID": ["UNIQUEIDENTIFIER"],
        "Spatial": ["GEOMETRY", "GEOGRAPHY"],
        "Other": ["SQL_VARIANT", "TIMESTAMP", "ROWVERSION", "CURSOR", "TABLE", "HIERARCHYID"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "[",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "TOP", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "COLUMN", "RENAME", "EXEC",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "IDENTITY", "NOLOCK", "WITH", "ROWCOUNT", "NEWID",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF", "IIF",
            "UNION", "INTERSECT", "EXCEPT",
            "DECLARE", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
            "PRINT", "GO", "EXECUTE",
            "OVER", "PARTITION", "ROW_NUMBER", "RANK", "DENSE_RANK",
            "RETURNING", "OUTPUT", "INSERTED", "DELETED"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "STRING_AGG",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LEN", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "CHARINDEX", "PATINDEX",
            "STUFF", "FORMAT",
            "GETDATE", "GETUTCDATE", "SYSDATETIME", "CURRENT_TIMESTAMP",
            "DATEADD", "DATEDIFF", "DATENAME", "DATEPART",
            "CONVERT", "CAST",
            "ROUND", "CEILING", "FLOOR", "ABS", "POWER", "SQRT", "RAND",
            "ISNULL", "ISNUMERIC", "ISDATE", "COALESCE", "NEWID",
            "OBJECT_ID", "OBJECT_NAME", "SCHEMA_NAME", "DB_NAME",
            "SCOPE_IDENTITY", "@@IDENTITY", "@@ROWCOUNT"
        ],
        dataTypes: [
            "INT", "INTEGER", "TINYINT", "SMALLINT", "BIGINT",
            "DECIMAL", "NUMERIC", "FLOAT", "REAL", "MONEY", "SMALLMONEY",
            "CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "TEXT", "NTEXT",
            "BINARY", "VARBINARY", "IMAGE",
            "DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET",
            "BIT", "UNIQUEIDENTIFIER", "XML", "SQL_VARIANT",
            "ROWVERSION", "TIMESTAMP", "HIERARCHYID"
        ],
        tableOptions: [
            "ON", "CLUSTERED", "NONCLUSTERED", "WITH", "TEXTIMAGE_ON"
        ],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch,
        autoLimitStyle: .top
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MSSQLPluginDriver(config: config)
    }
}

// MARK: - Global FreeTDS initialization

private let freetdsLastErrorLock = NSLock()
private var _freetdsLastError = ""

private var freetdsLastError: String {
    get {
        freetdsLastErrorLock.lock()
        defer { freetdsLastErrorLock.unlock() }
        return _freetdsLastError
    }
    set {
        freetdsLastErrorLock.lock()
        defer { freetdsLastErrorLock.unlock() }
        _freetdsLastError = newValue
    }
}

private let freetdsLogger = Logger(subsystem: "com.TablePro", category: "FreeTDSConnection")

private let freetdsInitOnce: Void = {
    _ = dbinit()
    _ = dberrhandle { _, _, dberr, _, dberrstr, oserrstr in
        var msg = "db-lib error \(dberr)"
        if let s = dberrstr { msg += ": \(String(cString: s))" }
        if let s = oserrstr, String(cString: s) != "Success" { msg += " (os: \(String(cString: s)))" }
        freetdsLogger.error("FreeTDS: \(msg)")
        if freetdsLastError.isEmpty {
            freetdsLastError = msg
        }
        return INT_CANCEL
    }
    _ = dbmsghandle { _, msgno, _, severity, msgtext, _, _, _ in
        guard let text = msgtext else { return 0 }
        let msg = String(cString: text)
        if severity > 10 {
            freetdsLastError = msg
            freetdsLogger.error("FreeTDS msg \(msgno) sev \(severity): \(msg)")
        } else {
            freetdsLogger.debug("FreeTDS msg \(msgno): \(msg)")
        }
        return 0
    }
}()

// MARK: - FreeTDS Connection

private struct FreeTDSQueryResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let affectedRows: Int
    let isTruncated: Bool
}

private final class FreeTDSConnection: @unchecked Sendable {
    private var dbproc: UnsafeMutablePointer<DBPROCESS>?
    private let queue: DispatchQueue
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    private let lock = NSLock()
    private var _isConnected = false
    private var _isCancelled = false

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    init(host: String, port: Int, user: String, password: String, database: String) {
        self.queue = DispatchQueue(label: "com.TablePro.freetds.\(host).\(port)", qos: .userInitiated)
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        _ = freetdsInitOnce
    }

    func connect() async throws {
        try await pluginDispatchAsync(on: queue) { [self] in
            try self.connectSync()
        }
    }

    private func connectSync() throws {
        guard let login = dblogin() else {
            throw MSSQLPluginError.connectionFailed("Failed to create login")
        }
        defer { dbloginfree(login) }

        _ = dbsetlname(login, user, Int32(DBSETUSER))
        _ = dbsetlname(login, password, Int32(DBSETPWD))
        _ = dbsetlname(login, "TablePro", Int32(DBSETAPP))
        _ = dbsetlversion(login, UInt8(DBVERSION_74))

        freetdsLastError = ""
        let serverName = "\(host):\(port)"
        guard let proc = dbopen(login, serverName) else {
            let detail = freetdsLastError.isEmpty ? "Check host, port, and credentials" : freetdsLastError
            throw MSSQLPluginError.connectionFailed("Failed to connect to \(host):\(port) — \(detail)")
        }

        if !database.isEmpty {
            if dbuse(proc, database) == FAIL {
                _ = dbclose(proc)
                throw MSSQLPluginError.connectionFailed("Cannot open database '\(database)'")
            }
        }

        self.dbproc = proc
        lock.lock()
        _isConnected = true
        lock.unlock()
    }

    func switchDatabase(_ database: String) async throws {
        try await pluginDispatchAsync(on: queue) { [self] in
            guard let proc = self.dbproc else {
                throw MSSQLPluginError.notConnected
            }
            if dbuse(proc, database) == FAIL {
                throw MSSQLPluginError.queryFailed("Cannot switch to database '\(database)'")
            }
        }
    }

    func disconnect() {
        let handle = dbproc
        dbproc = nil

        lock.lock()
        _isConnected = false
        lock.unlock()

        if let handle = handle {
            queue.async {
                _ = dbclose(handle)
            }
        }
    }

    func cancelCurrentQuery() {
        lock.lock()
        _isCancelled = true
        let proc = dbproc
        lock.unlock()

        guard let proc else { return }
        dbcancel(proc)
    }

    func executeQuery(_ query: String) async throws -> FreeTDSQueryResult {
        let queryToRun = String(query)
        return try await pluginDispatchAsync(on: queue) { [self] in
            try self.executeQuerySync(queryToRun)
        }
    }

    private func executeQuerySync(_ query: String) throws -> FreeTDSQueryResult {
        guard let proc = dbproc else {
            throw MSSQLPluginError.notConnected
        }

        _ = dbcanquery(proc)

        lock.lock()
        _isCancelled = false
        lock.unlock()

        freetdsLastError = ""
        if dbcmd(proc, query) == FAIL {
            throw MSSQLPluginError.queryFailed("Failed to prepare query")
        }
        if dbsqlexec(proc) == FAIL {
            let detail = freetdsLastError.isEmpty ? "Query execution failed" : freetdsLastError
            throw MSSQLPluginError.queryFailed(detail)
        }

        var allColumns: [String] = []
        var allTypeNames: [String] = []
        var allRows: [[String?]] = []
        var firstResultSet = true
        var truncated = false

        while true {
            lock.lock()
            let cancelledBetweenResults = _isCancelled
            if cancelledBetweenResults { _isCancelled = false }
            lock.unlock()
            if cancelledBetweenResults {
                throw MSSQLPluginError.queryFailed("Query cancelled")
            }

            let resCode = dbresults(proc)
            if resCode == FAIL {
                throw MSSQLPluginError.queryFailed("Query execution failed")
            }
            if resCode == Int32(NO_MORE_RESULTS) {
                break
            }

            let numCols = dbnumcols(proc)
            if numCols <= 0 { continue }

            var cols: [String] = []
            var typeNames: [String] = []
            for i in 1...numCols {
                let name = dbcolname(proc, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
                cols.append(name)
                typeNames.append(Self.freetdsTypeName(dbcoltype(proc, Int32(i))))
            }

            if firstResultSet {
                allColumns = cols
                allTypeNames = typeNames
                firstResultSet = false
            }

            while true {
                let rowCode = dbnextrow(proc)
                if rowCode == Int32(NO_MORE_ROWS) { break }
                if rowCode == FAIL { break }

                lock.lock()
                let cancelled = _isCancelled
                if cancelled { _isCancelled = false }
                lock.unlock()
                if cancelled {
                    throw MSSQLPluginError.queryFailed("Query cancelled")
                }

                var row: [String?] = []
                for i in 1...numCols {
                    let len = dbdatlen(proc, Int32(i))
                    let colType = dbcoltype(proc, Int32(i))
                    if len <= 0 && colType != Int32(SYBBIT) {
                        row.append(nil)
                    } else if let ptr = dbdata(proc, Int32(i)) {
                        let str = Self.columnValueAsString(proc: proc, ptr: ptr, srcType: colType, srcLen: len)
                        row.append(str)
                    } else {
                        row.append(nil)
                    }
                }
                allRows.append(row)
                if allRows.count >= PluginRowLimits.defaultMax {
                    truncated = true
                    break
                }
            }
        }

        let affectedRows = allColumns.isEmpty ? 0 : allRows.count
        return FreeTDSQueryResult(
            columns: allColumns,
            columnTypeNames: allTypeNames,
            rows: allRows,
            affectedRows: affectedRows,
            isTruncated: truncated
        )
    }

    private static func columnValueAsString(proc: UnsafeMutablePointer<DBPROCESS>, ptr: UnsafePointer<BYTE>, srcType: Int32, srcLen: DBINT) -> String? {
        switch srcType {
        case Int32(SYBCHAR), Int32(SYBVARCHAR), Int32(SYBTEXT):
            return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .utf8)
                ?? String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .isoLatin1)
        case Int32(SYBNCHAR), Int32(SYBNVARCHAR), Int32(SYBNTEXT):
            let data = Data(bytes: ptr, count: Int(srcLen))
            return String(data: data, encoding: .utf16LittleEndian)
        default:
            let bufSize: DBINT = 64
            var buf = [BYTE](repeating: 0, count: Int(bufSize))
            let converted = buf.withUnsafeMutableBufferPointer { bufPtr in
                dbconvert(proc, srcType, ptr, srcLen, Int32(SYBCHAR), bufPtr.baseAddress, bufSize)
            }
            if converted > 0 {
                return String(bytes: buf.prefix(Int(converted)), encoding: .utf8)
            }
            return nil
        }
    }

    private static func freetdsTypeName(_ type: Int32) -> String {
        switch type {
        case Int32(SYBCHAR), Int32(SYBVARCHAR): return "varchar"
        case Int32(SYBNCHAR), Int32(SYBNVARCHAR): return "nvarchar"
        case Int32(SYBTEXT): return "text"
        case Int32(SYBNTEXT): return "ntext"
        case Int32(SYBINT1): return "tinyint"
        case Int32(SYBINT2): return "smallint"
        case Int32(SYBINT4): return "int"
        case Int32(SYBINT8): return "bigint"
        case Int32(SYBFLT8): return "float"
        case Int32(SYBREAL): return "real"
        case Int32(SYBDECIMAL), Int32(SYBNUMERIC): return "decimal"
        case Int32(SYBMONEY), Int32(SYBMONEY4): return "money"
        case Int32(SYBBIT): return "bit"
        case Int32(SYBBINARY), Int32(SYBVARBINARY): return "varbinary"
        case Int32(SYBIMAGE): return "image"
        case Int32(SYBDATETIME), Int32(SYBDATETIMN): return "datetime"
        case Int32(SYBDATETIME4): return "smalldatetime"
        case Int32(SYBUNIQUE): return "uniqueidentifier"
        default: return "unknown"
        }
    }
}

// MARK: - MSSQL Plugin Driver

final class MSSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var freeTDSConn: FreeTDSConnection?
    private var _currentSchema: String
    private var _serverVersion: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "MSSQLPluginDriver")

    var currentSchema: String? { _currentSchema }
    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "]", with: "]]")
        return "[\(escaped)]"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR ALTER VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR ALTER VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS NVARCHAR(MAX))"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self._currentSchema = config.additionalFields["mssqlSchema"]?.isEmpty == false
            ? config.additionalFields["mssqlSchema"]!
            : "dbo"
    }

    private var escapedSchema: String {
        _currentSchema.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Connection

    func connect() async throws {
        let conn = FreeTDSConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database
        )
        try await conn.connect()
        self.freeTDSConn = conn
        if let result = try? await conn.executeQuery("SELECT @@VERSION"),
           let versionStr = result.rows.first?.first ?? nil {
            _serverVersion = String(versionStr.prefix(50))
        }
    }

    func disconnect() {
        freeTDSConn?.disconnect()
        freeTDSConn = nil
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        _ = try await execute(query: "BEGIN TRANSACTION")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        guard let conn = freeTDSConn else {
            throw MSSQLPluginError.notConnected
        }
        let startTime = Date()
        let result = try await conn.executeQuery(query)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: result.isTruncated
        )
    }

    // MARK: - DML Statement Generation

    func generateStatements(
        table: String,
        columns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        var statements: [(statement: String, parameters: [String?])] = []

        var deleteChanges: [PluginRowChange] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let values = insertedRowData[change.rowIndex] {
                    if let stmt = generateMssqlInsert(table: table, columns: columns, values: values) {
                        statements.append(stmt)
                    }
                }
            case .update:
                if let stmt = generateMssqlUpdate(table: table, columns: columns, change: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                deleteChanges.append(change)
            }
        }

        if !deleteChanges.isEmpty {
            for change in deleteChanges {
                if let stmt = generateMssqlDelete(table: table, columns: columns, change: change) {
                    statements.append(stmt)
                }
            }
        }

        return statements.isEmpty ? nil : statements
    }

    private func generateMssqlInsert(
        table: String,
        columns: [String],
        values: [String?]
    ) -> (statement: String, parameters: [String?])? {
        var nonDefaultColumns: [String] = []
        var parameters: [String?] = []

        for (index, value) in values.enumerated() {
            if value == "__DEFAULT__" { continue }
            guard index < columns.count else { continue }
            nonDefaultColumns.append("[\(columns[index].replacingOccurrences(of: "]", with: "]]"))]")
            parameters.append(value)
        }

        guard !nonDefaultColumns.isEmpty else { return nil }

        let columnList = nonDefaultColumns.joined(separator: ", ")
        let placeholders = parameters.map { _ in "?" }.joined(separator: ", ")
        let escapedTable = "[\(table.replacingOccurrences(of: "]", with: "]]"))]"
        let sql = "INSERT INTO \(escapedTable) (\(columnList)) VALUES (\(placeholders))"
        return (statement: sql, parameters: parameters)
    }

    private func generateMssqlUpdate(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard !change.cellChanges.isEmpty else { return nil }

        let escapedTable = "[\(table.replacingOccurrences(of: "]", with: "]]"))]"
        var parameters: [String?] = []

        let setClauses = change.cellChanges.map { cellChange -> String in
            let col = "[\(cellChange.columnName.replacingOccurrences(of: "]", with: "]]"))]"
            parameters.append(cellChange.newValue)
            return "\(col) = ?"
        }.joined(separator: ", ")

        // Check if we have original row data to identify by PK or all columns
        guard let originalRow = change.originalRow else { return nil }

        // Use all columns as WHERE clause for safety
        var conditions: [String] = []
        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = "[\(columnName.replacingOccurrences(of: "]", with: "]]"))]"
            if let value = originalRow[index] {
                parameters.append(value)
                conditions.append("\(col) = ?")
            } else {
                conditions.append("\(col) IS NULL")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")

        // Without a reliable PK, use UPDATE TOP (1) for safety
        let sql = "UPDATE TOP (1) \(escapedTable) SET \(setClauses) WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    private func generateMssqlDelete(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard let originalRow = change.originalRow else { return nil }

        let escapedTable = "[\(table.replacingOccurrences(of: "]", with: "]]"))]"
        var parameters: [String?] = []
        var conditions: [String] = []

        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = "[\(columnName.replacingOccurrences(of: "]", with: "]]"))]"
            if let value = originalRow[index] {
                parameters.append(value)
                conditions.append("\(col) = ?")
            } else {
                conditions.append("\(col) IS NULL")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = "DELETE TOP (1) FROM \(escapedTable) WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    func cancelQuery() throws {
        freeTDSConn?.cancelCurrentQuery()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        let ms = seconds * 1_000
        _ = try await execute(query: "SET LOCK_TIMEOUT \(ms)")
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        let (convertedQuery, paramDecls, paramAssigns) = Self.buildSpExecuteSql(
            query: query, parameters: parameters
        )

        // If no placeholders were found, execute the query as-is
        guard !paramDecls.isEmpty else {
            return try await execute(query: query)
        }

        let sql = "EXEC sp_executesql N'\(Self.escapeNString(convertedQuery))', N'\(paramDecls)', \(paramAssigns)"
        return try await execute(query: sql)
    }

    func fetchRowCount(query: String) async throws -> Int {
        let countQuery = "SELECT COUNT_BIG(*) FROM (\(query)) AS __cnt"
        let result = try await execute(query: countQuery)
        guard let row = result.rows.first,
              let cell = row.first,
              let str = cell,
              let count = Int(str) else {
            return 0
        }
        return count
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        var base = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix(";") {
            base = String(base.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        base = stripMSSQLOffsetFetch(from: base)
        let orderBy = hasTopLevelOrderBy(base) ? "" : " ORDER BY (SELECT NULL)"
        let paginated = "\(base)\(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return try await execute(query: paginated)
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let esc = (schema ?? _currentSchema).replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let objectName = "[\(esc)].[\(escapedTable)]"
        let sql = """
            SELECT SUM(p.rows)
            FROM sys.partitions p
            WHERE p.object_id = OBJECT_ID(N'\(objectName)') AND p.index_id IN (0, 1)
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first, let cell = row.first, let str = cell {
            return Int(str)
        }
        return nil
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT t.TABLE_NAME, t.TABLE_TYPE
            FROM INFORMATION_SCHEMA.TABLES t
            WHERE t.TABLE_SCHEMA = '\(esc)'
              AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            ORDER BY t.TABLE_NAME
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let rawType = row[safe: 1] ?? nil
            let tableType = (rawType == "VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT,
                COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA + '.' + c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY,
                CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
            FROM INFORMATION_SCHEMA.COLUMNS c
            LEFT JOIN (
                SELECT kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = '\(esc)'
                    AND tc.TABLE_NAME = '\(escapedTable)'
            ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_NAME = '\(escapedTable)'
              AND c.TABLE_SCHEMA = '\(esc)'
            ORDER BY c.ORDINAL_POSITION
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let dataType = row[safe: 1] ?? nil
            let charLen = row[safe: 2] ?? nil
            let numPrecision = row[safe: 3] ?? nil
            let numScale = row[safe: 4] ?? nil
            let isNullable = (row[safe: 5] ?? nil) == "YES"
            let defaultValue = row[safe: 6] ?? nil
            let isIdentity = (row[safe: 7] ?? nil) == "1"
            let isPk = (row[safe: 8] ?? nil) == "1"

            let baseType = (dataType ?? "nvarchar").lowercased()
            let fixedSizeTypes: Set<String> = [
                "int", "bigint", "smallint", "tinyint", "bit",
                "money", "smallmoney", "float", "real",
                "datetime", "datetime2", "smalldatetime", "date", "time",
                "uniqueidentifier", "text", "ntext", "image", "xml",
                "timestamp", "rowversion"
            ]
            var fullType = baseType
            if fixedSizeTypes.contains(baseType) {
                // No suffix
            } else if let charLen, let len = Int(charLen), len > 0 {
                fullType += "(\(len))"
            } else if charLen == "-1" {
                fullType += "(max)"
            } else if let prec = numPrecision, let scale = numScale,
                      let p = Int(prec), let s = Int(scale) {
                fullType += "(\(p),\(s))"
            }

            return PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue,
                extra: isIdentity ? "IDENTITY" : nil
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let esc = (schema ?? _currentSchema).replacingOccurrences(of: "]", with: "]]")
        let bracketedTable = table.replacingOccurrences(of: "]", with: "]]")
        let bracketedFull = "[\(esc)].[\(bracketedTable)]"
        let sql = """
            SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID('\(bracketedFull)')
              AND i.name IS NOT NULL
            ORDER BY i.index_id, ic.key_ordinal
            """
        let result = try await execute(query: sql)
        var indexMap: [String: (unique: Bool, primary: Bool, columns: [String])] = [:]
        for row in result.rows {
            guard let idxName = row[safe: 0] ?? nil,
                  let colName = row[safe: 3] ?? nil else { continue }
            let isUnique = (row[safe: 1] ?? nil) == "1"
            let isPrimary = (row[safe: 2] ?? nil) == "1"
            if indexMap[idxName] == nil {
                indexMap[idxName] = (unique: isUnique, primary: isPrimary, columns: [])
            }
            indexMap[idxName]?.columns.append(colName)
        }
        return indexMap.map { name, info in
            PluginIndexInfo(
                name: name,
                columns: info.columns,
                isUnique: info.unique,
                isPrimary: info.primary,
                type: "CLUSTERED"
            )
        }.sorted { $0.name < $1.name }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                fk.name AS constraint_name,
                cp.name AS column_name,
                tr.name AS ref_table,
                cr.name AS ref_column
            FROM sys.foreign_keys fk
            JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
            JOIN sys.tables tp ON fkc.parent_object_id = tp.object_id
            JOIN sys.schemas s ON tp.schema_id = s.schema_id
            JOIN sys.columns cp
                ON fkc.parent_object_id = cp.object_id AND fkc.parent_column_id = cp.column_id
            JOIN sys.tables tr ON fkc.referenced_object_id = tr.object_id
            JOIN sys.columns cr
                ON fkc.referenced_object_id = cr.object_id AND fkc.referenced_column_id = cr.column_id
            WHERE tp.name = '\(escapedTable)' AND s.name = '\(esc)'
            ORDER BY fk.name
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard let constraintName = row[safe: 0] ?? nil,
                  let columnName = row[safe: 1] ?? nil,
                  let refTable = row[safe: 2] ?? nil,
                  let refColumn = row[safe: 3] ?? nil else { return nil }
            return PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                c.TABLE_NAME,
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT,
                COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA + '.' + c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY,
                CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
            FROM INFORMATION_SCHEMA.COLUMNS c
            LEFT JOIN (
                SELECT kcu.TABLE_NAME, kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = '\(esc)'
            ) pk ON c.TABLE_NAME = pk.TABLE_NAME AND c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_SCHEMA = '\(esc)'
            ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
            """
        let result = try await execute(query: sql)
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0] ?? nil,
                  let name = row[safe: 1] ?? nil else { continue }
            let dataType = row[safe: 2] ?? nil
            let charLen = row[safe: 3] ?? nil
            let numPrecision = row[safe: 4] ?? nil
            let numScale = row[safe: 5] ?? nil
            let isNullable = (row[safe: 6] ?? nil) == "YES"
            let defaultValue = row[safe: 7] ?? nil
            let isIdentity = (row[safe: 8] ?? nil) == "1"
            let isPk = (row[safe: 9] ?? nil) == "1"

            let baseType = (dataType ?? "nvarchar").lowercased()
            let fixedSizeTypes: Set<String> = [
                "int", "bigint", "smallint", "tinyint", "bit",
                "money", "smallmoney", "float", "real",
                "datetime", "datetime2", "smalldatetime", "date", "time",
                "uniqueidentifier", "text", "ntext", "image", "xml",
                "timestamp", "rowversion"
            ]
            var fullType = baseType
            if fixedSizeTypes.contains(baseType) {
                // No suffix
            } else if let charLen, let len = Int(charLen), len > 0 {
                fullType += "(\(len))"
            } else if charLen == "-1" {
                fullType += "(max)"
            } else if let prec = numPrecision, let scale = numScale,
                      let p = Int(prec), let s = Int(scale) {
                fullType += "(\(p),\(s))"
            }

            let col = PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue,
                extra: isIdentity ? "IDENTITY" : nil
            )
            columnsByTable[tableName, default: []].append(col)
        }
        return columnsByTable
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                tp.name AS table_name,
                fk.name AS constraint_name,
                cp.name AS column_name,
                tr.name AS ref_table,
                cr.name AS ref_column
            FROM sys.foreign_keys fk
            JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
            JOIN sys.tables tp ON fkc.parent_object_id = tp.object_id
            JOIN sys.schemas s ON tp.schema_id = s.schema_id
            JOIN sys.columns cp
                ON fkc.parent_object_id = cp.object_id AND fkc.parent_column_id = cp.column_id
            JOIN sys.tables tr ON fkc.referenced_object_id = tr.object_id
            JOIN sys.columns cr
                ON fkc.referenced_object_id = cr.object_id AND fkc.referenced_column_id = cr.column_id
            WHERE s.name = '\(esc)'
            ORDER BY tp.name, fk.name
            """
        let result = try await execute(query: sql)
        var fksByTable: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0] ?? nil,
                  let constraintName = row[safe: 1] ?? nil,
                  let columnName = row[safe: 2] ?? nil,
                  let refTable = row[safe: 3] ?? nil,
                  let refColumn = row[safe: 4] ?? nil else { continue }
            let fk = PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn
            )
            fksByTable[tableName, default: []].append(fk)
        }
        return fksByTable
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let sql = """
            SELECT d.name,
                   SUM(mf.size) * 8 * 1024 AS size_bytes
            FROM sys.databases d
            LEFT JOIN sys.master_files mf ON d.database_id = mf.database_id
            GROUP BY d.name
            ORDER BY d.name
            """
        do {
            let result = try await execute(query: sql)
            var metadata = result.rows.compactMap { row -> PluginDatabaseMetadata? in
                guard let name = row[safe: 0] ?? nil else { return nil }
                let sizeBytes = (row[safe: 1] ?? nil).flatMap { Int64($0) }
                return PluginDatabaseMetadata(name: name, sizeBytes: sizeBytes)
            }

            for i in metadata.indices {
                let dbName = metadata[i].name.replacingOccurrences(of: "]", with: "]]")
                do {
                    let countResult = try await execute(
                        query: "SELECT COUNT(*) FROM [\(dbName)].sys.tables"
                    )
                    if let countStr = countResult.rows.first?[safe: 0] ?? nil,
                       let count = Int(countStr) {
                        metadata[i] = PluginDatabaseMetadata(
                            name: metadata[i].name,
                            tableCount: count,
                            sizeBytes: metadata[i].sizeBytes
                        )
                    }
                } catch {
                    // Database offline or permission denied — leave tableCount as nil
                }
            }

            return metadata
        } catch {
            // Fall back to N+1 if permission denied on sys.master_files
            let dbs = try await fetchDatabases()
            var result: [PluginDatabaseMetadata] = []
            for db in dbs {
                do {
                    result.append(try await fetchDatabaseMetadata(db))
                } catch {
                    result.append(PluginDatabaseMetadata(name: db))
                }
            }
            return result
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let cols = try await fetchColumns(table: table, schema: schema)
        let indexes = try await fetchIndexes(table: table, schema: schema)
        let fks = try await fetchForeignKeys(table: table, schema: schema)

        var ddl = "CREATE TABLE [\(esc)].[\(escapedTable)] (\n"
        let colDefs = cols.map { col -> String in
            var def = "    [\(col.name)] \(col.dataType.uppercased())"
            if col.extra == "IDENTITY" { def += " IDENTITY(1,1)" }
            def += col.isNullable ? " NULL" : " NOT NULL"
            if let d = col.defaultValue { def += " DEFAULT \(d)" }
            return def
        }

        let pkCols = indexes.filter(\.isPrimary).flatMap(\.columns)
        var parts = colDefs
        if !pkCols.isEmpty {
            let pkName = "PK_\(table)"
            let pkDef = "    CONSTRAINT [\(pkName)] PRIMARY KEY (\(pkCols.map { "[\($0)]" }.joined(separator: ", ")))"
            parts.append(pkDef)
        }

        for fk in fks {
            let fkDef = "    CONSTRAINT [\(fk.name)] FOREIGN KEY ([\(fk.column)]) REFERENCES [\(fk.referencedTable)] ([\(fk.referencedColumn)])"
            parts.append(fkDef)
        }

        ddl += parts.joined(separator: ",\n")
        ddl += "\n);"
        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let esc = effectiveSchemaEscaped(schema)
        let escapedView = "\(esc).\(view.replacingOccurrences(of: "'", with: "''"))"
        let sql = "SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('\(escapedView)')"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.flatMap { $0 } ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                SUM(p.rows) AS row_count,
                8 * SUM(a.used_pages) AS size_kb,
                ep.value AS comment
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.partitions p
                ON t.object_id = p.object_id AND p.index_id IN (0, 1)
            JOIN sys.allocation_units a ON p.partition_id = a.container_id
            LEFT JOIN sys.extended_properties ep
                ON ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
            WHERE t.name = '\(escapedTable)' AND s.name = '\(esc)'
            GROUP BY ep.value
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let rowCount = (row[safe: 0] ?? nil).flatMap { Int64($0) }
            let sizeKb = (row[safe: 1] ?? nil).flatMap { Int64($0) } ?? 0
            let comment = row[safe: 2] ?? nil
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeKb * 1_024,
                totalSize: sizeKb * 1_024,
                rowCount: rowCount,
                comment: comment
            )
        }
        return PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] {
        let sql = "SELECT name FROM sys.databases ORDER BY name"
        let result = try await execute(query: sql)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func fetchSchemas() async throws -> [String] {
        let sql = """
            SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA
            WHERE SCHEMA_NAME NOT IN (
                'information_schema','sys','db_owner','db_accessadmin',
                'db_securityadmin','db_ddladmin','db_backupoperator',
                'db_datareader','db_datawriter','db_denydatareader',
                'db_denydatawriter','guest'
            )
            ORDER BY SCHEMA_NAME
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func switchSchema(to schema: String) async throws {
        _currentSchema = schema
    }

    func switchDatabase(to database: String) async throws {
        guard let conn = freeTDSConn else {
            throw MSSQLPluginError.notConnected
        }
        try await conn.switchDatabase(database)
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let sql = """
            SELECT
                SUM(size) * 8.0 / 1024 AS size_mb,
                (SELECT COUNT(*) FROM sys.tables) AS table_count
            FROM sys.database_files
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let sizeMb = (row[safe: 0] ?? nil).flatMap { Double($0) } ?? 0
            let tableCount = (row[safe: 1] ?? nil).flatMap { Int($0) } ?? 0
            return PluginDatabaseMetadata(
                name: database,
                tableCount: tableCount,
                sizeBytes: Int64(sizeMb * 1_024 * 1_024)
            )
        }
        return PluginDatabaseMetadata(name: database)
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        let quotedName = "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
        _ = try await execute(query: "CREATE DATABASE \(quotedName)")
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            s.name as schema_name,
            t.name as name,
            CASE WHEN v.object_id IS NOT NULL THEN 'VIEW' ELSE 'TABLE' END as kind,
            p.rows as estimated_rows,
            CAST(ROUND(SUM(a.total_pages) * 8 / 1024.0, 2) AS VARCHAR) + ' MB' as total_size
        FROM sys.tables t
        INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
        INNER JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0, 1)
        INNER JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
        INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
        LEFT JOIN sys.views v ON t.object_id = v.object_id
        GROUP BY s.name, t.name, p.rows, v.object_id
        ORDER BY t.name
        """
    }

    // MARK: - Query Building

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let quotedTable = mssqlQuoteIdentifier(table)
        var query = "SELECT * FROM \(quotedTable)"
        let orderBy = mssqlBuildOrderByClause(sortColumns: sortColumns, columns: columns)
            ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let quotedTable = mssqlQuoteIdentifier(table)
        var query = "SELECT * FROM \(quotedTable)"
        let whereClause = mssqlBuildWhereClause(filters: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            query += " WHERE \(whereClause)"
        }
        let orderBy = mssqlBuildOrderByClause(sortColumns: sortColumns, columns: columns)
            ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    // MARK: - Query Building Helpers

    private func mssqlQuoteIdentifier(_ identifier: String) -> String {
        quoteIdentifier(identifier)
    }

    private func mssqlBuildOrderByClause(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> String? {
        let parts = sortColumns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let columnName = columns[sortCol.columnIndex]
            let direction = sortCol.ascending ? "ASC" : "DESC"
            let quotedColumn = mssqlQuoteIdentifier(columnName)
            return "\(quotedColumn) \(direction)"
        }
        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    private func mssqlEscapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "'", with: "''")
    }

    private func mssqlEscapeValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare("NULL") == .orderedSame { return "NULL" }
        if trimmed.caseInsensitiveCompare("TRUE") == .orderedSame { return "1" }
        if trimmed.caseInsensitiveCompare("FALSE") == .orderedSame { return "0" }
        if Int(trimmed) != nil || Double(trimmed) != nil { return trimmed }
        return "'\(trimmed.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func mssqlBuildWhereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) -> String {
        let conditions = filters.compactMap { filter -> String? in
            mssqlBuildFilterCondition(column: filter.column, op: filter.op, value: filter.value)
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    private func mssqlBuildFilterCondition(column: String, op: String, value: String) -> String? {
        let quoted = mssqlQuoteIdentifier(column)
        switch op {
        case "=": return "\(quoted) = \(mssqlEscapeValue(value))"
        case "!=": return "\(quoted) != \(mssqlEscapeValue(value))"
        case ">": return "\(quoted) > \(mssqlEscapeValue(value))"
        case ">=": return "\(quoted) >= \(mssqlEscapeValue(value))"
        case "<": return "\(quoted) < \(mssqlEscapeValue(value))"
        case "<=": return "\(quoted) <= \(mssqlEscapeValue(value))"
        case "IS NULL": return "\(quoted) IS NULL"
        case "IS NOT NULL": return "\(quoted) IS NOT NULL"
        case "IS EMPTY": return "(\(quoted) IS NULL OR \(quoted) = '')"
        case "IS NOT EMPTY": return "(\(quoted) IS NOT NULL AND \(quoted) != '')"
        case "CONTAINS":
            let escaped = mssqlEscapeForLike(value)
            return "\(quoted) LIKE '%\(escaped)%' ESCAPE '\\'"
        case "NOT CONTAINS":
            let escaped = mssqlEscapeForLike(value)
            return "\(quoted) NOT LIKE '%\(escaped)%' ESCAPE '\\'"
        case "STARTS WITH":
            let escaped = mssqlEscapeForLike(value)
            return "\(quoted) LIKE '\(escaped)%' ESCAPE '\\'"
        case "ENDS WITH":
            let escaped = mssqlEscapeForLike(value)
            return "\(quoted) LIKE '%\(escaped)' ESCAPE '\\'"
        case "IN":
            let values = value.split(separator: ",")
                .map { mssqlEscapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) IN (\(values))"
        case "NOT IN":
            let values = value.split(separator: ",")
                .map { mssqlEscapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) NOT IN (\(values))"
        case "BETWEEN":
            let parts = value.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let v1 = mssqlEscapeValue(parts[0].trimmingCharacters(in: .whitespaces))
            let v2 = mssqlEscapeValue(parts[1].trimmingCharacters(in: .whitespaces))
            return "\(quoted) BETWEEN \(v1) AND \(v2)"
        case "REGEX":
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            return "\(quoted) LIKE '%\(escaped)%'"
        default: return nil
        }
    }

    // MARK: - Private Helpers

    /// Convert `?` placeholders to `@p1, @p2, ...` and build sp_executesql components.
    /// Returns: (convertedQuery, paramDeclarations, paramAssignments)
    private static func buildSpExecuteSql(
        query: String,
        parameters: [String?]
    ) -> (String, String, String) {
        var converted = ""
        var paramIndex = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        let chars = Array(query)
        let length = chars.count

        var i = 0
        while i < length {
            let char = chars[i]

            // Handle doubled quotes (T-SQL escape: '' inside strings, "" inside identifiers)
            if char == "'" && inSingleQuote && i + 1 < length && chars[i + 1] == "'" {
                converted.append("''")
                i += 2
                continue
            }
            if char == "\"" && inDoubleQuote && i + 1 < length && chars[i + 1] == "\"" {
                converted.append("\"\"")
                i += 2
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            }

            if char == "?" && !inSingleQuote && !inDoubleQuote && paramIndex < parameters.count {
                paramIndex += 1
                converted.append("@p\(paramIndex)")
            } else {
                converted.append(char)
            }
            i += 1
        }

        let count = paramIndex
        guard count > 0 else {
            return (converted, "", "")
        }
        let decls = (1...count).map { "@p\($0) NVARCHAR(MAX)" }.joined(separator: ", ")
        let assigns = (1...count).map { i -> String in
            if let value = parameters[i - 1] {
                return "@p\(i) = N'\(escapeNString(value))'"
            }
            return "@p\(i) = NULL"
        }.joined(separator: ", ")

        return (converted, decls, assigns)
    }

    /// Escape single quotes for N'...' string literals in SQL Server.
    private static func escapeNString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func effectiveSchemaEscaped(_ schema: String?) -> String {
        let raw = schema ?? _currentSchema
        return raw.replacingOccurrences(of: "'", with: "''")
    }

    private func hasTopLevelOrderBy(_ query: String) -> Bool {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 8 else { return false }
        var depth = 0
        var i = len - 1
        while i >= 7 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x59 {
                let start = i - 7
                if start >= 0 {
                    let candidate = ns.substring(with: NSRange(location: start, length: 8))
                    if candidate == "ORDER BY" { return true }
                }
            }
            i -= 1
        }
        return false
    }

    private func stripMSSQLOffsetFetch(from query: String) -> String {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 6 else { return query }
        var depth = 0
        var i = len - 1
        while i >= 5 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x54 {
                let start = i - 5
                if start >= 0 {
                    let candidate = ns.substring(with: NSRange(location: start, length: 6))
                    if candidate == "OFFSET" {
                        return (query as NSString).substring(to: start)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            i -= 1
        }
        return query
    }
}

// MARK: - Errors

enum MSSQLPluginError: Error {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
}

extension MSSQLPluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .queryFailed(let msg): return msg
        }
    }
}
