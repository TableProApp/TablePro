//
//  ClickHousePlugin.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class ClickHousePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "ClickHouse Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "ClickHouse database support via HTTP interface"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "ClickHouse"
    static let databaseDisplayName = "ClickHouse"
    static let iconName = "clickhouse-icon"
    static let defaultPort = 8123

    // MARK: - UI/Capability Metadata

    static let isDownloadable = true
    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "pipeline", label: "Pipeline", sqlPrefix: "EXPLAIN PIPELINE"),
        ExplainVariant(id: "ast", label: "AST", sqlPrefix: "EXPLAIN AST"),
        ExplainVariant(id: "syntax", label: "Syntax", sqlPrefix: "EXPLAIN SYNTAX"),
        ExplainVariant(id: "estimate", label: "Estimate", sqlPrefix: "EXPLAIN ESTIMATE"),
    ]
    static let brandColorHex = "#FFD100"
    static let postConnectActions: [PostConnectAction] = [.selectDatabaseFromLastSession]
    static let supportsForeignKeys = false
    static let systemDatabaseNames: [String] = ["information_schema", "INFORMATION_SCHEMA", "system"]
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": [
            "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
            "Int8", "Int16", "Int32", "Int64", "Int128", "Int256"
        ],
        "Float": ["Float32", "Float64", "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256"],
        "String": ["String", "FixedString", "Enum8", "Enum16"],
        "Date": ["Date", "Date32", "DateTime", "DateTime64"],
        "Binary": [],
        "Boolean": ["Bool"],
        "JSON": ["JSON"],
        "UUID": ["UUID"],
        "Array": ["Array"],
        "Map": ["Map"],
        "Tuple": ["Tuple"],
        "IP": ["IPv4", "IPv6"],
        "Geo": ["Point", "Ring", "Polygon", "MultiPolygon"]
    ]

    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue, .comment]
    static let supportsQueryProgress = true
    static let supportsDropDatabase = true

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE",
            "UNION", "INTERSECT", "EXCEPT",
            "FINAL", "SAMPLE", "PREWHERE", "GLOBAL", "FORMAT", "SETTINGS",
            "OPTIMIZE", "SYSTEM", "PARTITION", "TTL", "ENGINE", "CODEC",
            "MATERIALIZED", "WITH"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE",
            "NOW", "TODAY", "YESTERDAY",
            "CAST",
            "UNIQ", "UNIQEXACT", "ARGMIN", "ARGMAX", "GROUPARRAY",
            "TOSTRING", "TOINT32", "FORMATDATETIME",
            "IF", "MULTIIF",
            "ARRAYMAP", "ARRAYJOIN",
            "MATCH", "CURRENTDATABASE", "VERSION",
            "QUANTILE", "TOPK"
        ],
        dataTypes: [
            "INT8", "INT16", "INT32", "INT64", "INT128", "INT256",
            "UINT8", "UINT16", "UINT32", "UINT64", "UINT128", "UINT256",
            "FLOAT32", "FLOAT64",
            "DECIMAL", "DECIMAL32", "DECIMAL64", "DECIMAL128", "DECIMAL256",
            "STRING", "FIXEDSTRING", "UUID",
            "DATE", "DATE32", "DATETIME", "DATETIME64",
            "ARRAY", "TUPLE", "MAP",
            "NULLABLE", "LOWCARDINALITY",
            "ENUM8", "ENUM16",
            "IPV4", "IPV6",
            "JSON", "BOOL"
        ],
        tableOptions: [
            "ENGINE=MergeTree()", "ORDER BY", "PARTITION BY", "SETTINGS"
        ],
        regexSyntax: .match,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit,
        paginationStyle: .limit,
        requiresBackslashEscaping: true
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        ClickHousePluginDriver(config: config)
    }
}

// MARK: - Error Types

private struct ClickHouseError: Error, PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }

    static let notConnected = ClickHouseError(message: String(localized: "Not connected to database"))
    static let connectionFailed = ClickHouseError(message: String(localized: "Failed to establish connection"))
}

// MARK: - Internal Query Result

private struct CHQueryResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let affectedRows: Int
    let isTruncated: Bool
}

// MARK: - Plugin Driver

final class ClickHousePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var _serverVersion: String?

    private let lock = NSLock()
    private var session: URLSession?
    private var currentTask: URLSessionDataTask?
    private var _currentDatabase: String
    private var _lastQueryId: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ClickHousePluginDriver")

    private static let selectPrefixes: Set<String> = [
        "SELECT", "SHOW", "DESCRIBE", "DESC", "EXISTS", "EXPLAIN", "WITH"
    ]

    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        result = result.replacingOccurrences(of: "\0", with: "\\0")
        result = result.replacingOccurrences(of: "\u{08}", with: "\\b")
        result = result.replacingOccurrences(of: "\u{0C}", with: "\\f")
        result = result.replacingOccurrences(of: "\u{1A}", with: "\\Z")
        return result
    }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    var currentSchema: String? { nil }

    init(config: DriverConnectionConfig) {
        self.config = config
        self._currentDatabase = config.database
    }

    // MARK: - Connection

    func connect() async throws {
        let useTLS = config.additionalFields["sslMode"] != nil
            && config.additionalFields["sslMode"] != "Disabled"
        let skipVerification = config.additionalFields["sslMode"] == "Required"

        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = 30
        urlConfig.timeoutIntervalForResource = 300

        lock.lock()
        if skipVerification {
            session = URLSession(configuration: urlConfig, delegate: InsecureTLSDelegate(), delegateQueue: nil)
        } else {
            session = URLSession(configuration: urlConfig)
        }
        lock.unlock()

        do {
            _ = try await executeRaw("SELECT 1")
        } catch {
            lock.lock()
            session?.invalidateAndCancel()
            session = nil
            lock.unlock()
            Self.logger.error("Connection test failed: \(error.localizedDescription)")
            throw ClickHouseError.connectionFailed
        }

        if let result = try? await executeRaw("SELECT version()"),
           let versionStr = result.rows.first?.first ?? nil {
            _serverVersion = versionStr
        }

        Self.logger.debug("Connected to ClickHouse at \(self.config.host):\(self.config.port)")
    }

    func disconnect() {
        lock.lock()
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        lock.unlock()
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()
        let queryId = UUID().uuidString
        let result = try await executeRaw(query, queryId: queryId)
        let executionTime = Date().timeIntervalSince(startTime)

        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: executionTime,
            isTruncated: result.isTruncated
        )
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        let startTime = Date()
        let queryId = UUID().uuidString
        let (convertedQuery, paramMap) = Self.buildClickHouseParams(query: query, parameters: parameters)
        let result = try await executeRawWithParams(convertedQuery, params: paramMap, queryId: queryId)
        let executionTime = Date().timeIntervalSince(startTime)

        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: executionTime,
            isTruncated: result.isTruncated
        )
    }

    func fetchRowCount(query: String) async throws -> Int {
        let countQuery = "SELECT count() FROM (\(query)) AS __cnt"
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
        base = stripLimitOffset(from: base)
        let paginated = "\(base) LIMIT \(limit) OFFSET \(offset)"
        return try await execute(query: paginated)
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let sql = """
            SELECT name, engine FROM system.tables
            WHERE database = currentDatabase() AND name NOT LIKE '.%'
            ORDER BY name
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let engine = row[safe: 1] ?? nil
            let tableType = (engine?.contains("View") == true) ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let pkSql = """
            SELECT primary_key, sorting_key FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedTable)'
            """
        let pkResult = try await execute(query: pkSql)
        let primaryKey = pkResult.rows.first.flatMap { $0[safe: 0] ?? nil } ?? ""
        let sortingKey = pkResult.rows.first.flatMap { $0[safe: 1] ?? nil } ?? ""
        let keyString = primaryKey.isEmpty ? sortingKey : primaryKey
        let pkColumns = Set(keyString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

        let sql = """
            SELECT name, type, default_kind, default_expression, comment
            FROM system.columns
            WHERE database = currentDatabase() AND table = '\(escapedTable)'
            ORDER BY position
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let dataType = (row[safe: 1] ?? nil) ?? "String"
            let defaultKind = row[safe: 2] ?? nil
            let defaultExpr = row[safe: 3] ?? nil
            let comment = row[safe: 4] ?? nil

            let isNullable = dataType.hasPrefix("Nullable(")

            var defaultValue: String?
            if let kind = defaultKind, !kind.isEmpty, let expr = defaultExpr, !expr.isEmpty {
                defaultValue = expr
            }

            var extra: String?
            if let kind = defaultKind, !kind.isEmpty, kind != "DEFAULT" {
                extra = kind
            }

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: pkColumns.contains(name),
                defaultValue: defaultValue,
                extra: extra,
                comment: (comment?.isEmpty == false) ? comment : nil
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        // Pre-fetch PK columns for all tables. Falls back to sorting_key when
        // primary_key is empty (MergeTree without explicit PRIMARY KEY clause).
        // Note: expression-based keys like toDate(col) won't match bare column names.
        let pkSql = """
            SELECT name, primary_key, sorting_key FROM system.tables
            WHERE database = currentDatabase()
            """
        let pkResult = try await execute(query: pkSql)
        var pkLookup: [String: Set<String>] = [:]
        for row in pkResult.rows {
            guard let tableName = row[safe: 0] ?? nil else { continue }
            let primaryKey = (row[safe: 1] ?? nil) ?? ""
            let sortingKey = (row[safe: 2] ?? nil) ?? ""
            let keyString = primaryKey.isEmpty ? sortingKey : primaryKey
            guard !keyString.isEmpty else { continue }
            let cols = Set(keyString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            pkLookup[tableName] = cols
        }

        let sql = """
            SELECT table, name, type, default_kind, default_expression, comment
            FROM system.columns
            WHERE database = currentDatabase()
            ORDER BY table, position
            """
        let result = try await execute(query: sql)
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0] ?? nil,
                  let colName = row[safe: 1] ?? nil else { continue }
            let dataType = (row[safe: 2] ?? nil) ?? "String"
            let defaultKind = row[safe: 3] ?? nil
            let defaultExpr = row[safe: 4] ?? nil
            let comment = row[safe: 5] ?? nil

            let isNullable = dataType.hasPrefix("Nullable(")

            var defaultValue: String?
            if let kind = defaultKind, !kind.isEmpty, let expr = defaultExpr, !expr.isEmpty {
                defaultValue = expr
            }

            var extra: String?
            if let kind = defaultKind, !kind.isEmpty, kind != "DEFAULT" {
                extra = kind
            }

            let colInfo = PluginColumnInfo(
                name: colName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: pkLookup[tableName]?.contains(colName) == true,
                defaultValue: defaultValue,
                extra: extra,
                comment: (comment?.isEmpty == false) ? comment : nil
            )
            columnsByTable[tableName, default: []].append(colInfo)
        }
        return columnsByTable
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        var indexes: [PluginIndexInfo] = []

        let sortingKeySql = """
            SELECT sorting_key FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedTable)'
            """
        let sortingResult = try await execute(query: sortingKeySql)
        if let row = sortingResult.rows.first,
           let sortingKey = row[safe: 0] ?? nil, !sortingKey.isEmpty {
            let columns = sortingKey.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            indexes.append(PluginIndexInfo(
                name: "PRIMARY (sorting key)",
                columns: columns,
                isUnique: false,
                isPrimary: true,
                type: "SORTING KEY"
            ))
        }

        let skippingSql = """
            SELECT name, expr FROM system.data_skipping_indices
            WHERE database = currentDatabase() AND table = '\(escapedTable)'
            """
        let skippingResult = try await execute(query: skippingSql)
        for row in skippingResult.rows {
            guard let idxName = row[safe: 0] ?? nil else { continue }
            let expr = (row[safe: 1] ?? nil) ?? ""
            let columns = expr.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            indexes.append(PluginIndexInfo(
                name: idxName,
                columns: columns,
                isUnique: false,
                isPrimary: false,
                type: "DATA_SKIPPING"
            ))
        }

        return indexes
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT sum(rows) FROM system.parts
            WHERE database = currentDatabase() AND table = '\(escapedTable)' AND active = 1
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first, let cell = row.first, let str = cell {
            return Int(str)
        }
        return nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "`", with: "``")
        let sql = "SHOW CREATE TABLE `\(escapedTable)`"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.flatMap { $0 } ?? ""
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let escapedView = view.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT as_select FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedView)'
            """
        let result = try await execute(query: sql)
        return result.rows.first?.first?.flatMap { $0 } ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let engineSql = """
            SELECT engine, comment FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedTable)'
            """
        let engineResult = try await execute(query: engineSql)
        let engine = engineResult.rows.first.flatMap { $0[safe: 0] ?? nil }
        let tableComment = engineResult.rows.first.flatMap { $0[safe: 1] ?? nil }

        let partsSql = """
            SELECT sum(rows), sum(bytes_on_disk)
            FROM system.parts
            WHERE database = currentDatabase() AND table = '\(escapedTable)' AND active = 1
            """
        let partsResult = try await execute(query: partsSql)
        if let row = partsResult.rows.first {
            let rowCount = (row[safe: 0] ?? nil).flatMap { Int64($0) }
            let sizeBytes = (row[safe: 1] ?? nil).flatMap { Int64($0) } ?? 0
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeBytes,
                totalSize: sizeBytes,
                rowCount: rowCount,
                comment: (tableComment?.isEmpty == false) ? tableComment : nil,
                engine: engine
            )
        }

        return PluginTableMetadata(tableName: table, engine: engine)
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SHOW DATABASES")
        return result.rows.compactMap { $0.first ?? nil }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let escapedDb = database.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT count() AS table_count, sum(total_bytes) AS size_bytes
            FROM system.tables WHERE database = '\(escapedDb)'
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let tableCount = (row[safe: 0] ?? nil).flatMap { Int($0) } ?? 0
            let sizeBytes = (row[safe: 1] ?? nil).flatMap { Int64($0) }
            return PluginDatabaseMetadata(
                name: database,
                tableCount: tableCount,
                sizeBytes: sizeBytes
            )
        }
        return PluginDatabaseMetadata(name: database)
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let sql = """
            SELECT database, count() AS table_count, sum(total_bytes) AS size_bytes
            FROM system.tables
            GROUP BY database
            ORDER BY database
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginDatabaseMetadata? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let tableCount = (row[safe: 1] ?? nil).flatMap { Int($0) } ?? 0
            let sizeBytes = (row[safe: 2] ?? nil).flatMap { Int64($0) }
            return PluginDatabaseMetadata(name: name, tableCount: tableCount, sizeBytes: sizeBytes)
        }
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        let escapedName = name.replacingOccurrences(of: "`", with: "``")
        _ = try await execute(query: "CREATE DATABASE `\(escapedName)`")
    }

    func dropDatabase(name: String) async throws {
        let escapedName = name.replacingOccurrences(of: "`", with: "``")
        _ = try await execute(query: "DROP DATABASE `\(escapedName)`")
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            database as `schema`,
            name,
            engine as kind,
            total_rows as estimated_rows,
            formatReadableSize(total_bytes) as total_size,
            comment
        FROM system.tables
        WHERE database = currentDatabase()
        ORDER BY name
        """
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

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let values = insertedRowData[change.rowIndex] {
                    if let stmt = generateClickHouseInsert(table: table, columns: columns, values: values) {
                        statements.append(stmt)
                    }
                }
            case .update:
                if let stmt = generateClickHouseUpdate(table: table, columns: columns, change: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateClickHouseDelete(table: table, columns: columns, change: change) {
                    statements.append(stmt)
                }
            }
        }

        return statements.isEmpty ? nil : statements
    }

    private func generateClickHouseInsert(
        table: String,
        columns: [String],
        values: [String?]
    ) -> (statement: String, parameters: [String?])? {
        var nonDefaultColumns: [String] = []
        var parameters: [String?] = []

        for (index, value) in values.enumerated() {
            if value == "__DEFAULT__" { continue }
            guard index < columns.count else { continue }
            nonDefaultColumns.append("`\(columns[index].replacingOccurrences(of: "`", with: "``"))`")
            parameters.append(value)
        }

        guard !nonDefaultColumns.isEmpty else { return nil }

        let columnList = nonDefaultColumns.joined(separator: ", ")
        let placeholders = parameters.map { _ in "?" }.joined(separator: ", ")
        let sql = "INSERT INTO `\(table.replacingOccurrences(of: "`", with: "``"))` (\(columnList)) VALUES (\(placeholders))"
        return (statement: sql, parameters: parameters)
    }

    private func generateClickHouseUpdate(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard !change.cellChanges.isEmpty else { return nil }

        let escapedTable = "`\(table.replacingOccurrences(of: "`", with: "``"))`"
        var parameters: [String?] = []

        let setClauses = change.cellChanges.map { cellChange -> String in
            let col = "`\(cellChange.columnName.replacingOccurrences(of: "`", with: "``"))`"
            parameters.append(cellChange.newValue)
            return "\(col) = ?"
        }.joined(separator: ", ")

        guard let whereClause = buildWhereClause(
            columns: columns, change: change, parameters: &parameters
        ) else { return nil }

        let sql = "ALTER TABLE \(escapedTable) UPDATE \(setClauses) WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    private func generateClickHouseDelete(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        let escapedTable = "`\(table.replacingOccurrences(of: "`", with: "``"))`"
        var parameters: [String?] = []

        guard let whereClause = buildWhereClause(
            columns: columns, change: change, parameters: &parameters
        ) else { return nil }

        let sql = "ALTER TABLE \(escapedTable) DELETE WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    private func buildWhereClause(
        columns: [String],
        change: PluginRowChange,
        parameters: inout [String?]
    ) -> String? {
        guard let originalRow = change.originalRow else { return nil }

        var conditions: [String] = []
        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = "`\(columnName.replacingOccurrences(of: "`", with: "``"))`"
            if let value = originalRow[index] {
                parameters.append(value)
                conditions.append("\(col) = ?")
            } else {
                conditions.append("\(col) IS NULL")
            }
        }

        guard !conditions.isEmpty else { return nil }
        return conditions.joined(separator: " AND ")
    }

    func cancelQuery() throws {
        let queryId: String?
        lock.lock()
        queryId = _lastQueryId
        currentTask?.cancel()
        currentTask = nil
        lock.unlock()

        if let queryId, !queryId.isEmpty {
            killQuery(queryId: queryId)
        }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        _ = try await execute(query: "SET max_execution_time = \(seconds)")
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        lock.lock()
        _currentDatabase = database
        lock.unlock()
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - Kill Query

    private func killQuery(queryId: String) {
        lock.lock()
        let hasSession = session != nil
        lock.unlock()
        guard hasSession else { return }

        let killConfig = URLSessionConfiguration.default
        killConfig.timeoutIntervalForRequest = 5
        let killSession = URLSession(configuration: killConfig)

        do {
            let escapedId = queryId.replacingOccurrences(of: "'", with: "''")
            let request = try buildRequest(
                query: "KILL QUERY WHERE query_id = '\(escapedId)'",
                database: ""
            )
            let task = killSession.dataTask(with: request) { _, _, _ in
                killSession.invalidateAndCancel()
            }
            task.resume()
        } catch {
            killSession.invalidateAndCancel()
        }
    }

    // MARK: - Private HTTP Layer

    private func executeRaw(_ query: String, queryId: String? = nil) async throws -> CHQueryResult {
        lock.lock()
        guard let session = self.session else {
            lock.unlock()
            throw ClickHouseError.notConnected
        }
        let database = _currentDatabase
        if let queryId {
            _lastQueryId = queryId
        }
        lock.unlock()

        let request = try buildRequest(query: query, database: database, queryId: queryId)
        let isSelect = Self.isSelectLikeQuery(query)

        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: ClickHouseError(message: "Empty response from server"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }

                self.lock.lock()
                self.currentTask = task
                self.lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.currentTask?.cancel()
            self.currentTask = nil
            self.lock.unlock()
        }

        lock.lock()
        currentTask = nil
        lock.unlock()

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.logger.error("ClickHouse HTTP \(httpResponse.statusCode): \(body)")
            throw ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if isSelect {
            return parseTabSeparatedResponse(data)
        }

        return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
    }

    private func executeRawWithParams(_ query: String, params: [String: String?], queryId: String? = nil) async throws -> CHQueryResult {
        lock.lock()
        guard let session = self.session else {
            lock.unlock()
            throw ClickHouseError.notConnected
        }
        let database = _currentDatabase
        if let queryId {
            _lastQueryId = queryId
        }
        lock.unlock()

        let request = try buildRequest(query: query, database: database, queryId: queryId, params: params)
        let isSelect = Self.isSelectLikeQuery(query)

        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: ClickHouseError(message: "Empty response from server"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                self.lock.lock()
                self.currentTask = task
                self.lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.currentTask?.cancel()
            self.currentTask = nil
            self.lock.unlock()
        }

        lock.lock()
        currentTask = nil
        lock.unlock()

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.logger.error("ClickHouse HTTP \(httpResponse.statusCode): \(body)")
            throw ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if isSelect {
            return parseTabSeparatedResponse(data)
        }

        return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
    }

    private func buildRequest(query: String, database: String, queryId: String? = nil, params: [String: String?]? = nil) throws -> URLRequest {
        let useTLS = config.additionalFields["sslMode"] != nil
            && config.additionalFields["sslMode"] != "Disabled"

        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = config.host
        components.port = config.port
        components.path = "/"

        var queryItems = [URLQueryItem]()
        if !database.isEmpty {
            queryItems.append(URLQueryItem(name: "database", value: database))
        }
        if let queryId {
            queryItems.append(URLQueryItem(name: "query_id", value: queryId))
        }
        queryItems.append(URLQueryItem(name: "send_progress_in_http_headers", value: "1"))
        if let params {
            for (key, value) in params.sorted(by: { $0.key < $1.key }) {
                queryItems.append(URLQueryItem(name: "param_\(key)", value: value))
            }
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ClickHouseError(message: "Failed to construct request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let credentials = "\(config.username):\(config.password)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ";+$", with: "", options: .regularExpression)

        if Self.isSelectLikeQuery(trimmedQuery) {
            request.httpBody = (trimmedQuery + " FORMAT TabSeparatedWithNamesAndTypes").data(using: .utf8)
        } else {
            request.httpBody = trimmedQuery.data(using: .utf8)
        }

        return request
    }

    private static func isSelectLikeQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = trimmed.split(separator: " ", maxSplits: 1).first else {
            return false
        }
        return selectPrefixes.contains(firstWord.uppercased())
    }

    private func parseTabSeparatedResponse(_ data: Data) -> CHQueryResult {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
        }

        let lines = text.components(separatedBy: "\n")

        guard lines.count >= 2 else {
            return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
        }

        let columns = lines[0].components(separatedBy: "\t")
        let columnTypes = lines[1].components(separatedBy: "\t")

        var rows: [[String?]] = []
        var truncated = false
        for i in 2..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }

            let fields = line.components(separatedBy: "\t")
            let row = fields.map { field -> String? in
                if field == "\\N" {
                    return nil
                }
                return Self.unescapeTsvField(field)
            }
            rows.append(row)
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }
        }

        return CHQueryResult(
            columns: columns,
            columnTypeNames: columnTypes,
            rows: rows,
            affectedRows: rows.count,
            isTruncated: truncated
        )
    }

    private static func unescapeTsvField(_ field: String) -> String {
        var result = ""
        result.reserveCapacity((field as NSString).length)
        var iterator = field.makeIterator()

        while let char = iterator.next() {
            if char == "\\" {
                if let next = iterator.next() {
                    switch next {
                    case "\\": result.append("\\")
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    default:
                        result.append("\\")
                        result.append(next)
                    }
                } else {
                    result.append("\\")
                }
            } else {
                result.append(char)
            }
        }

        return result
    }

    private func stripLimitOffset(from query: String) -> String {
        let ns = query as NSString
        let len = ns.length
        guard len > 0 else { return query }

        let upper = query.uppercased() as NSString
        var depth = 0
        var i = len - 1

        while i >= 4 {
            let ch = upper.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x54 {
                let start = i - 4
                if start >= 0 {
                    let candidate = upper.substring(with: NSRange(location: start, length: 5))
                    if candidate == "LIMIT" {
                        if start == 0 || CharacterSet.whitespacesAndNewlines
                            .contains(UnicodeScalar(upper.character(at: start - 1)) ?? UnicodeScalar(0)) {
                            return ns.substring(to: start)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
            i -= 1
        }
        return query
    }

    /// Convert `?` placeholders to `{p1:String}` and build parameter map for ClickHouse HTTP params.
    private static func buildClickHouseParams(
        query: String,
        parameters: [String?]
    ) -> (String, [String: String?]) {
        var converted = ""
        var paramIndex = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for char in query {
            if isEscaped {
                isEscaped = false
                converted.append(char)
                continue
            }
            if char == "\\" && (inSingleQuote || inDoubleQuote) {
                isEscaped = true
                converted.append(char)
                continue
            }
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            }
            if char == "?" && !inSingleQuote && !inDoubleQuote && paramIndex < parameters.count {
                paramIndex += 1
                converted.append("{p\(paramIndex):String}")
            } else {
                converted.append(char)
            }
        }

        var paramMap: [String: String?] = [:]
        for i in 0..<paramIndex where i < parameters.count {
            paramMap["p\(i + 1)"] = parameters[i]
        }

        return (converted, paramMap)
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                do {
                    try await self.performStreamRows(query: query, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    private func performStreamRows(
        query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        lock.lock()
        guard let session = self.session else {
            lock.unlock()
            throw ClickHouseError.notConnected
        }
        let database = _currentDatabase
        lock.unlock()

        var trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedQuery.hasSuffix(";") {
            trimmedQuery = String(trimmedQuery.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let headerResult = try await executeRaw("\(trimmedQuery) LIMIT 0")
        continuation.yield(.header(PluginStreamHeader(
            columns: headerResult.columns,
            columnTypeNames: headerResult.columnTypeNames,
            estimatedRowCount: nil
        )))

        let columnOrder = headerResult.columns

        guard !columnOrder.isEmpty else {
            continuation.finish()
            return
        }

        let streamRequest = try buildStreamRequest(
            query: trimmedQuery, database: database
        )

        let (bytes, response) = try await session.bytes(for: streamRequest)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let batchSize = 5_000
        var batch: [PluginRow] = []
        batch.reserveCapacity(batchSize)

        for try await line in bytes.lines {
            try Task.checkCancellation()

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }

            guard let lineData = trimmedLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            var row: [String?] = []
            for colName in columnOrder {
                if let value = json[colName] {
                    if value is NSNull {
                        row.append(nil)
                    } else if let str = value as? String {
                        row.append(str)
                    } else if let num = value as? NSNumber {
                        row.append(num.stringValue)
                    } else {
                        if let jsonData = try? JSONSerialization.data(withJSONObject: value),
                           let jsonStr = String(data: jsonData, encoding: .utf8) {
                            row.append(jsonStr)
                        } else {
                            row.append(String(describing: value))
                        }
                    }
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

        continuation.finish()
    }

    private func buildStreamRequest(query: String, database: String) throws -> URLRequest {
        let useTLS = config.additionalFields["sslMode"] != nil
            && config.additionalFields["sslMode"] != "Disabled"

        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = config.host
        components.port = config.port
        components.path = "/"

        var queryItems = [URLQueryItem]()
        if !database.isEmpty {
            queryItems.append(URLQueryItem(name: "database", value: database))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ClickHouseError(message: "Failed to construct request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let credentials = "\(config.username):\(config.password)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = (query + " FORMAT JSONEachRow").data(using: .utf8)
        return request
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let tableName = quoteIdentifier(definition.tableName)
        let parts: [String] = definition.columns.map { clickhouseColumnDefinition($0) }

        var sql = "CREATE TABLE \(tableName) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n)"

        let engine = definition.engine ?? "MergeTree()"
        sql += "\nENGINE = \(engine)"

        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        if !pkColumns.isEmpty {
            let orderCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            sql += "\nORDER BY (\(orderCols))"
        } else {
            sql += "\nORDER BY tuple()"
        }

        return sql + ";"
    }

    private func clickhouseColumnDefinition(_ col: PluginColumnDefinition) -> String {
        var dataType = col.dataType
        if col.isNullable {
            let upper = dataType.uppercased()
            if !upper.hasPrefix("NULLABLE(") {
                dataType = "Nullable(\(dataType))"
            }
        }

        var def = "\(quoteIdentifier(col.name)) \(dataType)"
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(clickhouseDefaultValue(defaultValue))"
        }
        if let comment = col.comment, !comment.isEmpty {
            def += " COMMENT '\(escapeStringLiteral(comment))'"
        }
        return def
    }

    private func clickhouseDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "NOW()" || upper == "TODAY()"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(clickhouseColumnDefinition(column))"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let tableName = quoteIdentifier(table)
        var stmts: [String] = []
        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(tableName) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }
        if oldColumn.dataType != newColumn.dataType || oldColumn.isNullable != newColumn.isNullable
            || oldColumn.defaultValue != newColumn.defaultValue || oldColumn.comment != newColumn.comment {
            stmts.append("ALTER TABLE \(tableName) MODIFY COLUMN \(clickhouseColumnDefinition(newColumn))")
        }
        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let indexType = index.indexType ?? "minmax"
        return "ALTER TABLE \(quoteIdentifier(table)) ADD INDEX \(quoteIdentifier(index.name)) (\(cols)) TYPE \(indexType) GRANULARITY 1"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP INDEX \(quoteIdentifier(indexName))"
    }

    // MARK: - TLS Delegate

    private class InsecureTLSDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
