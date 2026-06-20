//
//  MSSQLPlugin.swift
//  TablePro
//

import Foundation
import os
import TableProMSSQLCore
import TableProPluginKit

// MARK: - Core ↔ Plugin Bridges

private extension MSSQLRawCell {
    var asPluginCell: PluginCellValue {
        switch self {
        case .null: return .null
        case .string(let s): return PluginCellValue.fromOptional(s)
        case .bytes(let d): return .bytes(d)
        }
    }
}

private extension MSSQLRawResult {
    func toPluginResult(executionTime: TimeInterval) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns.map { $0.name },
            columnTypeNames: columns.map { $0.type.canonicalName },
            rows: rows.map { row in row.map { $0.asPluginCell } },
            rowsAffected: affectedRows,
            executionTime: executionTime,
            isTruncated: isTruncated
        )
    }
}

private extension MSSQLPluginError {
    init(coreError: MSSQLCoreError) {
        switch coreError {
        case .notConnected:
            self = .notConnected
        case .connectionFailed(let m):
            self = .connectionFailed(m)
        case .queryFailed(let m):
            self = .queryFailed(m)
        case .cancelled:
            self = .queryFailed(String(localized: "Query was cancelled"))
        case .tlsHandshakeFailed(_, let serverMessage):
            self = .connectionFailed(String(format: String(localized: "TLS: %@"), serverMessage))
        }
    }
}

private extension MSSQLTLSFailureKind {
    func sslHandshakeError(serverMessage: String) -> SSLHandshakeError {
        switch self {
        case .serverRejectedPlaintext: return .serverRejectedPlaintext(serverMessage: serverMessage)
        case .serverRequiresPlaintext: return .serverRequiresPlaintext(serverMessage: serverMessage)
        case .untrustedCertificate: return .untrustedCertificate(serverMessage: serverMessage)
        case .hostnameMismatch: return .hostnameMismatch(serverMessage: serverMessage)
        case .clientCertRequired: return .clientCertRequired(serverMessage: serverMessage)
        case .cipherMismatch: return .cipherMismatch(serverMessage: serverMessage)
        }
    }
}

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

    static let supportsSchemaSwitching = true
    static let postConnectActions: [PostConnectAction] = [.selectDatabaseFromLastSession, .selectSchemaFromLastSession]
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

    static let supportsDropDatabase = true
    static let supportsTriggers = true
    static let supportsTriggerEditing = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MSSQLPluginDriver(config: config)
    }
}

// MARK: - MSSQL Plugin Driver

final class MSSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    var freeTDSConn: FreeTDSConnection?
    var _currentSchema: String
    private var _serverVersion: String?

    /// IDENTITY columns observed during `fetchColumns`, keyed by table name.
    /// `generateMssqlInsert` reads this to skip IDENTITY columns: SQL Server
    /// rejects explicit values for IDENTITY columns unless IDENTITY_INSERT is ON,
    /// and the value the user typed is server-allocated anyway.
    var identityColumnsByTable: [String: Set<String>] = [:]
    let identityCacheLock = NSLock()

    private static let logger = Logger(subsystem: "com.TablePro", category: "MSSQLPluginDriver")

    var currentSchema: String? { _currentSchema }
    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .cancelQuery,
            .batchExecute,
        ]
    }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "]", with: "]]")
        return "[\(escaped)]"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        if MSSQLCapabilities.parse(serverVersion).hasCreateOrAlterView {
            return "CREATE OR ALTER VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
        }
        return "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        if MSSQLCapabilities.parse(serverVersion).hasCreateOrAlterView {
            return "CREATE OR ALTER VIEW \(quoted) AS\nSELECT * FROM table_name;"
        }
        return "IF OBJECT_ID('\(viewName)', 'V') IS NOT NULL DROP VIEW \(quoted);\nCREATE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS NVARCHAR(MAX))"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self._currentSchema = config.additionalFields["mssqlSchema"].flatMap { $0.isEmpty ? nil : $0 } ?? "dbo"
    }

    private var escapedSchema: String {
        _currentSchema.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Connection

    func connect() async throws {
        let options = MSSQLConnectionOptions(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database,
            schema: _currentSchema,
            encryptionFlag: MSSQLSSLMapping.freetdsEncryptionFlag(for: config.ssl.mode)
        )
        let conn = FreeTDSConnection(options: options)
        do {
            try await conn.connect()
        } catch let error as MSSQLCoreError {
            if case let .tlsHandshakeFailed(kind, serverMessage) = error {
                throw kind.sslHandshakeError(serverMessage: serverMessage)
            }
            throw MSSQLPluginError(coreError: error)
        }
        self.freeTDSConn = conn

        if let result = try? await executeInternal("SELECT SCHEMA_NAME()"),
           let serverSchema = result.rows.first?.first?.asText,
           !serverSchema.isEmpty {
            _currentSchema = serverSchema
        } else {
            Self.logger.warning("SELECT SCHEMA_NAME() returned no value; keeping \(self._currentSchema, privacy: .public)")
        }

        let formSchema = config.additionalFields["mssqlSchema"]
        if let formSchema, !formSchema.isEmpty, formSchema != _currentSchema {
            _currentSchema = formSchema
        }

        if let result = try? await executeInternal("SELECT @@VERSION"),
           let versionStr = result.rows.first?.first?.asText {
            _serverVersion = String(versionStr.prefix(50))
        }
    }

    private func executeInternal(_ query: String) async throws -> PluginQueryResult {
        guard let conn = freeTDSConn else {
            throw MSSQLPluginError.notConnected
        }
        let startTime = Date()
        do {
            let raw = try await conn.executeQuery(query)
            return raw.toPluginResult(executionTime: Date().timeIntervalSince(startTime))
        } catch let error as MSSQLCoreError {
            throw MSSQLPluginError(coreError: error)
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
        try await executeInternal(query)
    }

    // MARK: - DML Statement Generation

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []

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
                if let stmt = generateMssqlUpdate(
                    table: table, columns: columns,
                    primaryKeyColumns: primaryKeyColumns, change: change
                ) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                deleteChanges.append(change)
            }
        }

        if !deleteChanges.isEmpty {
            for change in deleteChanges {
                if let stmt = generateMssqlDelete(
                    table: table, columns: columns,
                    primaryKeyColumns: primaryKeyColumns, change: change
                ) {
                    statements.append(stmt)
                }
            }
        }

        return statements.isEmpty ? nil : statements
    }

    private func generateMssqlInsert(
        table: String,
        columns: [String],
        values: [PluginCellValue]
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var nonDefaultColumns: [String] = []
        var parameters: [PluginCellValue] = []
        let identityColumns = cachedIdentityColumns(for: table)

        for (index, value) in values.enumerated() {
            if value.asText == "__DEFAULT__" { continue }
            guard index < columns.count else { continue }
            let columnName = columns[index]
            // SQL Server IDENTITY columns are server-allocated. INSERTs that include
            // an explicit value fail unless `SET IDENTITY_INSERT <table> ON` was issued,
            // so always omit them and let the server assign the next value.
            if identityColumns.contains(columnName) { continue }
            nonDefaultColumns.append("[\(columnName.replacingOccurrences(of: "]", with: "]]"))]")
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
        primaryKeyColumns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty else { return nil }
        guard let originalRow = change.originalRow else { return nil }

        let escapedTable = "[\(table.replacingOccurrences(of: "]", with: "]]"))]"
        var parameters: [PluginCellValue] = []

        let setClauses = change.cellChanges.map { cellChange -> String in
            let col = "[\(cellChange.columnName.replacingOccurrences(of: "]", with: "]]"))]"
            parameters.append(cellChange.newValue)
            return "\(col) = ?"
        }.joined(separator: ", ")

        let whereColumns: [String] = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns

        var conditions: [String] = []
        for whereColumn in whereColumns {
            guard let columnIndex = columns.firstIndex(of: whereColumn),
                  columnIndex < originalRow.count
            else { continue }
            let col = "[\(whereColumn.replacingOccurrences(of: "]", with: "]]"))]"
            let value = originalRow[columnIndex]
            if value.isNull {
                conditions.append("\(col) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(col) = ?")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")
        let topClause = primaryKeyColumns.isEmpty ? "TOP (1) " : ""
        let sql = "UPDATE \(topClause)\(escapedTable) SET \(setClauses) WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    private func generateMssqlDelete(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow else { return nil }

        let escapedTable = "[\(table.replacingOccurrences(of: "]", with: "]]"))]"
        var parameters: [PluginCellValue] = []
        var conditions: [String] = []

        let whereColumns: [String] = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns

        for whereColumn in whereColumns {
            guard let columnIndex = columns.firstIndex(of: whereColumn),
                  columnIndex < originalRow.count
            else { continue }
            let col = "[\(whereColumn.replacingOccurrences(of: "]", with: "]]"))]"
            let value = originalRow[columnIndex]
            if value.isNull {
                conditions.append("\(col) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(col) = ?")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")
        let topClause = primaryKeyColumns.isEmpty ? "TOP (1) " : ""
        let sql = "DELETE \(topClause)FROM \(escapedTable) WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let conn = freeTDSConn else {
            return AsyncThrowingStream { $0.finish(throwing: MSSQLPluginError.notConnected) }
        }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                let coreStream = AsyncThrowingStream<MSSQLStreamElement, Error> { coreContinuation in
                    Task {
                        do {
                            try await conn.streamQuery(query, continuation: coreContinuation)
                        } catch let error as MSSQLCoreError {
                            coreContinuation.finish(throwing: MSSQLPluginError(coreError: error))
                        } catch {
                            coreContinuation.finish(throwing: error)
                        }
                    }
                }
                do {
                    for try await element in coreStream {
                        switch element {
                        case .header(let columns):
                            continuation.yield(.header(PluginStreamHeader(
                                columns: columns.map { $0.name },
                                columnTypeNames: columns.map { $0.type.canonicalName },
                                estimatedRowCount: nil
                            )))
                        case .rows(let batch):
                            let pluginRows: [PluginRow] = batch.map { row in
                                row.map { $0.asPluginCell }
                            }
                            continuation.yield(.rows(pluginRows))
                        case .affectedRows:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    func cancelQuery() throws {
        freeTDSConn?.cancelCurrentQuery()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        let ms = seconds * 1_000
        _ = try await execute(query: "SET LOCK_TIMEOUT \(ms)")
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        let (convertedQuery, paramDecls, paramAssigns) = Self.buildSpExecuteSql(
            query: query, parameters: parameters.map { $0.asText }
        )

        // If no placeholders were found, execute the query as-is
        guard !paramDecls.isEmpty else {
            return try await execute(query: query)
        }

        let sql = "EXEC sp_executesql N'\(Self.escapeNString(convertedQuery))', N'\(paramDecls)', \(paramAssigns)"
        return try await execute(query: sql)
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
        if let row = result.rows.first, let cell = row.first, let str = cell.asText {
            return Int(str)
        }
        return nil
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
        let orderBy = PluginSQLFilter.buildOrderByClause(
            sortColumns: sortColumns, columns: columns, quoteIdentifier: mssqlQuoteIdentifier
        ) ?? "ORDER BY (SELECT NULL)"
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
        let whereClause = PluginSQLFilter.buildWhereClause(
            filters: filters,
            logicMode: logicMode,
            quoteIdentifier: mssqlQuoteIdentifier,
            escapeValue: mssqlEscapeValue,
            regexCondition: { quoted, value in
                "\(quoted) LIKE '%\(value.replacingOccurrences(of: "'", with: "''"))%'"
            }
        )
        if !whereClause.isEmpty {
            query += " WHERE \(whereClause)"
        }
        let orderBy = PluginSQLFilter.buildOrderByClause(
            sortColumns: sortColumns, columns: columns, quoteIdentifier: mssqlQuoteIdentifier
        ) ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    // MARK: - Query Building Helpers

    private func mssqlQuoteIdentifier(_ identifier: String) -> String {
        quoteIdentifier(identifier)
    }

    private func mssqlEscapeValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare("NULL") == .orderedSame { return "NULL" }
        if trimmed.caseInsensitiveCompare("TRUE") == .orderedSame { return "1" }
        if trimmed.caseInsensitiveCompare("FALSE") == .orderedSame { return "0" }
        if Int(trimmed) != nil || Double(trimmed) != nil { return trimmed }
        return "'\(trimmed.replacingOccurrences(of: "'", with: "''"))'"
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

    func effectiveSchemaEscaped(_ schema: String?) -> String {
        let raw = schema ?? _currentSchema
        return raw.replacingOccurrences(of: "'", with: "''")
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
