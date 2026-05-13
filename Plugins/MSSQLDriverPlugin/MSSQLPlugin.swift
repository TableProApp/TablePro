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
        case .tlsHandshakeFailed(let m):
            self = .connectionFailed(String(format: String(localized: "TLS: %@"), m))
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

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MSSQLPluginDriver(config: config)
    }
}

// MARK: - MSSQL Plugin Driver

final class MSSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var freeTDSConn: FreeTDSConnection?
    private var _currentSchema: String
    private var _serverVersion: String?

    /// IDENTITY columns observed during `fetchColumns`, keyed by table name.
    /// `generateMssqlInsert` reads this to skip IDENTITY columns: SQL Server
    /// rejects explicit values for IDENTITY columns unless IDENTITY_INSERT is ON,
    /// and the value the user typed is server-allocated anyway.
    private var identityColumnsByTable: [String: Set<String>] = [:]
    private let identityCacheLock = NSLock()

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
        self._currentSchema = config.additionalFields["mssqlSchema"]?.isEmpty == false
            ? config.additionalFields["mssqlSchema"]!
            : "dbo"
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
            guard let name = row[safe: 0]?.asText else { return nil }
            let rawType = row[safe: 1]?.asText
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
        var identityColumns: Set<String> = []
        let columns: [PluginColumnInfo] = result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let dataType = row[safe: 1]?.asText
            let charLen = row[safe: 2]?.asText
            let numPrecision = row[safe: 3]?.asText
            let numScale = row[safe: 4]?.asText
            let isNullable = (row[safe: 5]?.asText) == "YES"
            let defaultValue = row[safe: 6]?.asText
            let isIdentity = (row[safe: 7]?.asText) == "1"
            let isPk = (row[safe: 8]?.asText) == "1"

            if isIdentity {
                identityColumns.insert(name)
            }

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
        identityCacheLock.lock()
        identityColumnsByTable[table] = identityColumns
        identityCacheLock.unlock()
        return columns
    }

    /// Snapshot of IDENTITY columns observed by the most recent `fetchColumns` for the table.
    /// Returns an empty set when `fetchColumns` hasn't run for this table yet, so callers
    /// fall through to including every typed value (matching pre-cache behavior).
    internal func cachedIdentityColumns(for table: String) -> Set<String> {
        identityCacheLock.lock()
        defer { identityCacheLock.unlock() }
        return identityColumnsByTable[table] ?? []
    }

    /// Test seam: pre-populate the cache so generateMssqlInsert can be exercised
    /// without going through a live `fetchColumns` round-trip.
    internal func setIdentityColumnsForTesting(_ columns: Set<String>, table: String) {
        identityCacheLock.lock()
        identityColumnsByTable[table] = columns
        identityCacheLock.unlock()
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
            guard let idxName = row[safe: 0]?.asText,
                  let colName = row[safe: 3]?.asText else { continue }
            let isUnique = (row[safe: 1]?.asText) == "1"
            let isPrimary = (row[safe: 2]?.asText) == "1"
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
            guard let constraintName = row[safe: 0]?.asText,
                  let columnName = row[safe: 1]?.asText,
                  let refTable = row[safe: 2]?.asText,
                  let refColumn = row[safe: 3]?.asText else { return nil }
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
            guard let tableName = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText else { continue }
            let dataType = row[safe: 2]?.asText
            let charLen = row[safe: 3]?.asText
            let numPrecision = row[safe: 4]?.asText
            let numScale = row[safe: 5]?.asText
            let isNullable = (row[safe: 6]?.asText) == "YES"
            let defaultValue = row[safe: 7]?.asText
            let isIdentity = (row[safe: 8]?.asText) == "1"
            let isPk = (row[safe: 9]?.asText) == "1"

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
            guard let tableName = row[safe: 0]?.asText,
                  let constraintName = row[safe: 1]?.asText,
                  let columnName = row[safe: 2]?.asText,
                  let refTable = row[safe: 3]?.asText,
                  let refColumn = row[safe: 4]?.asText else { continue }
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
                guard let name = row[safe: 0]?.asText else { return nil }
                let sizeBytes = (row[safe: 1]?.asText).flatMap { Int64($0) }
                return PluginDatabaseMetadata(name: name, sizeBytes: sizeBytes)
            }

            for i in metadata.indices {
                let dbName = metadata[i].name.replacingOccurrences(of: "]", with: "]]")
                do {
                    let countResult = try await execute(
                        query: "SELECT COUNT(*) FROM [\(dbName)].sys.tables"
                    )
                    if let countStr = countResult.rows.first?[safe: 0]?.asText,
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
        return result.rows.first?.first?.asText ?? ""
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
            let rowCount = (row[safe: 0]?.asText).flatMap { Int64($0) }
            let sizeKb = (row[safe: 1]?.asText).flatMap { Int64($0) } ?? 0
            let comment = row[safe: 2]?.asText
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
        return result.rows.compactMap { $0.first?.asText }
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
        return result.rows.compactMap { $0.first?.asText }
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
            let sizeMb = (row[safe: 0]?.asText).flatMap { Double($0) } ?? 0
            let tableCount = (row[safe: 1]?.asText).flatMap { Int($0) } ?? 0
            return PluginDatabaseMetadata(
                name: database,
                tableCount: tableCount,
                sizeBytes: Int64(sizeMb * 1_024 * 1_024)
            )
        }
        return PluginDatabaseMetadata(name: database)
    }

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(fields: [], footnote: nil)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let quotedName = "[\(request.name.replacingOccurrences(of: "]", with: "]]"))]"
        _ = try await execute(query: "CREATE DATABASE \(quotedName)")
    }

    func dropDatabase(name: String) async throws {
        let quotedName = "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
        _ = try await execute(query: "DROP DATABASE \(quotedName)")
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

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let schema = _currentSchema
        let qualifiedTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(definition.tableName))"
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { mssqlColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(mssqlForeignKeyDefinition(fk))
        }

        var sql = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        var indexStatements: [String] = []
        for index in definition.indexes {
            indexStatements.append(mssqlIndexDefinition(index, qualifiedTable: qualifiedTable))
        }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }

        return sql
    }

    private func mssqlColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        var def = "\(quoteIdentifier(col.name)) \(col.dataType)"
        if col.autoIncrement {
            def += " IDENTITY(1,1)"
        }
        if col.isNullable {
            def += " NULL"
        } else {
            def += " NOT NULL"
        }
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(mssqlDefaultValue(defaultValue))"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    private func mssqlDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "GETDATE()" || upper == "NEWID()" || upper == "GETUTCDATE()"
            || value.hasPrefix("'") || value.hasPrefix("(") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    private func mssqlIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        var def = "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
        if let type = index.indexType?.uppercased(), type == "CLUSTERED" {
            def = "CREATE \(unique)CLUSTERED INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
        } else if let type = index.indexType?.uppercased(), type == "NONCLUSTERED" {
            def = "CREATE \(unique)NONCLUSTERED INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
        }
        return def
    }

    private func mssqlForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        var def = "CONSTRAINT \(quoteIdentifier(fk.name)) FOREIGN KEY (\(cols)) REFERENCES \(quoteIdentifier(fk.referencedTable)) (\(refCols))"
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    // MARK: - ALTER TABLE DDL

    private func mssqlQualifiedTable(_ table: String) -> String {
        "\(quoteIdentifier(_currentSchema)).\(quoteIdentifier(table))"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) ADD \(mssqlColumnDefinition(column, inlinePK: false))"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = mssqlQualifiedTable(table)
        var stmts: [String] = []
        let needsTypeChange = oldColumn.dataType != newColumn.dataType || oldColumn.isNullable != newColumn.isNullable
        let defaultChanged = oldColumn.defaultValue != newColumn.defaultValue

        // Rename column first so subsequent statements reference the correct name
        if oldColumn.name != newColumn.name {
            let escapedPath = "\(escapeStringLiteral(_currentSchema)).\(escapeStringLiteral(table)).\(escapeStringLiteral(oldColumn.name))"
            stmts.append("EXEC sp_rename '\(escapedPath)', '\(escapeStringLiteral(newColumn.name))', 'COLUMN'")
        }

        let colName = quoteIdentifier(newColumn.name)

        // Drop existing default constraint before ALTER COLUMN or default change
        if (defaultChanged || needsTypeChange) && oldColumn.defaultValue != nil {
            let objectId = escapeStringLiteral("\(_currentSchema).\(table)")
            stmts.append("""
                DECLARE @dfName NVARCHAR(256); \
                SELECT @dfName = dc.name FROM sys.default_constraints dc \
                JOIN sys.columns c ON dc.parent_column_id = c.column_id AND dc.parent_object_id = c.object_id \
                WHERE c.name = '\(escapeStringLiteral(newColumn.name))' \
                AND dc.parent_object_id = OBJECT_ID('\(objectId)'); \
                IF @dfName IS NOT NULL EXEC('ALTER TABLE \(qt) DROP CONSTRAINT [' + @dfName + ']')
                """)
        }

        if needsTypeChange {
            let nullable = newColumn.isNullable ? "NULL" : "NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(newColumn.dataType) \(nullable)")
        }

        if defaultChanged, let defaultValue = newColumn.defaultValue {
            stmts.append("ALTER TABLE \(qt) ADD DEFAULT \(mssqlDefaultValue(defaultValue)) FOR \(colName)")
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        mssqlIndexDefinition(index, qualifiedTable: mssqlQualifiedTable(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(indexName)) ON \(mssqlQualifiedTable(table))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) ADD \(mssqlForeignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        let qt = mssqlQualifiedTable(table)
        var stmts: [String] = []
        if !oldColumns.isEmpty {
            let name = constraintName.map { quoteIdentifier($0) } ?? "/* unknown constraint */"
            stmts.append("ALTER TABLE \(qt) DROP CONSTRAINT \(name)")
        }
        if !newColumns.isEmpty {
            let cols = newColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
            let pkName = constraintName.map { quoteIdentifier($0) } ?? quoteIdentifier("PK_\(table)")
            stmts.append("ALTER TABLE \(qt) ADD CONSTRAINT \(pkName) PRIMARY KEY (\(cols))")
        }
        return stmts.isEmpty ? nil : stmts
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
