//
//  CloudflareD1PluginDriver.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

// MARK: - Error

private struct CloudflareD1Error: Error, PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }

    static let notConnected = CloudflareD1Error(message: String(localized: "Not connected to database"))
}

// MARK: - Plugin Driver

final class CloudflareD1PluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var httpClient: D1HttpClient?
    private var _serverVersion: String?
    private var databaseNameToUuid: [String: String] = [:]
    private let lock = NSLock()

    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudflareD1PluginDriver")

    var serverVersion: String? {
        lock.lock()
        defer { lock.unlock() }
        return _serverVersion
    }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var parameterStyle: ParameterStyle { .questionMark }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection

    func connect() async throws {
        guard let accountId = config.additionalFields["cfAccountId"], !accountId.isEmpty else {
            throw CloudflareD1Error(message: String(localized: "Account ID is required"))
        }

        let apiToken = config.password
        guard !apiToken.isEmpty else {
            throw CloudflareD1Error(message: String(localized: "API Token is required"))
        }

        let databaseName = config.database
        guard !databaseName.isEmpty else {
            throw CloudflareD1Error(message: String(localized: "Database name or UUID is required"))
        }

        let databaseId: String
        if isUuid(databaseName) {
            databaseId = databaseName
        } else {
            let client = D1HttpClient(accountId: accountId, apiToken: apiToken, databaseId: "")
            client.createSession()
            defer { client.invalidateSession() }
            let databases = try await client.listDatabases()

            guard let match = databases.first(where: { $0.name == databaseName }) else {
                throw CloudflareD1Error(
                    message: String(localized: "Database '\(databaseName)' not found in account")
                )
            }
            databaseId = match.uuid

            lock.lock()
            for db in databases {
                databaseNameToUuid[db.name] = db.uuid
            }
            lock.unlock()
        }

        let client = D1HttpClient(accountId: accountId, apiToken: apiToken, databaseId: databaseId)
        client.createSession()

        do {
            let details = try await client.getDatabaseDetails()
            lock.lock()
            _serverVersion = details.version ?? "D1"
            lock.unlock()
        } catch {
            client.invalidateSession()
            Self.logger.error("Connection test failed: \(error.localizedDescription)")
            throw CloudflareD1Error(message: String(localized: "Failed to connect to Cloudflare D1"))
        }

        lock.lock()
        httpClient = client
        lock.unlock()

        Self.logger.debug("Connected to Cloudflare D1 database: \(databaseName)")
    }

    func disconnect() {
        lock.lock()
        httpClient?.invalidateSession()
        httpClient = nil
        lock.unlock()
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let startTime = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try await client.executeRaw(sql: trimmed)
        let executionTime = Date().timeIntervalSince(startTime)
        return mapRawResult(payload, executionTime: executionTime)
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let startTime = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let anyParams: [Any?] = parameters.map { $0 as Any? }
        let payload = try await client.executeRaw(sql: trimmed, params: anyParams)
        let executionTime = Date().timeIntervalSince(startTime)
        return mapRawResult(payload, executionTime: executionTime)
    }

    func executeBatch(queries: [String]) async throws -> [PluginQueryResult] {
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let startTime = Date()
        let statements = queries.map { (sql: $0, params: nil as [Any?]?) }
        let payloads = try await client.executeBatchRaw(statements: statements)
        let elapsed = Date().timeIntervalSince(startTime)

        return payloads.enumerated().map { _, payload in
            mapRawResult(payload, executionTime: payload.meta?.duration ?? (elapsed / Double(payloads.count)))
        }
    }

    func cancelQuery() throws {
        lock.lock()
        httpClient?.cancelCurrentTask()
        lock.unlock()
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
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery = stripLimitOffset(from: trimmed)
        let payload = try await client.executeRaw(sql: baseQuery)

        let columns = payload.results.columns ?? []
        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columns.map { _ in "" },
            estimatedRowCount: nil
        )))

        let rawRows = payload.results.rows ?? []
        if !rawRows.isEmpty {
            let rows = rawRows.map { rawRow in rawRow.map(\.stringValue) }
            continuation.yield(.rows(rows))
        }

        continuation.finish()
    }

    // MARK: - Pagination

    func fetchRowCount(query: String) async throws -> Int {
        let baseQuery = stripLimitOffset(from: query)
        let countQuery = "SELECT COUNT(*) FROM (\(baseQuery)) _t"
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
            AND name NOT GLOB '_cf_*'
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
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name NOT GLOB '_cf_*'
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
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name NOT GLOB '_cf_*'
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
            throw CloudflareD1Error(message: "Failed to fetch DDL for table '\(table)'")
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
            throw CloudflareD1Error(message: "Failed to fetch definition for view '\(view)'")
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
            engine: "Cloudflare D1"
        )
    }

    // MARK: - Database Operations

    func fetchDatabases() async throws -> [String] {
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let databases = try await client.listDatabases()

        lock.lock()
        databaseNameToUuid.removeAll()
        for db in databases {
            databaseNameToUuid[db.name] = db.uuid
        }
        lock.unlock()

        return databases.map(\.name)
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let newDb = try await client.createDatabase(name: name)

        lock.lock()
        databaseNameToUuid[newDb.name] = newDb.uuid
        lock.unlock()
    }

    func switchDatabase(to database: String) async throws {
        lock.lock()
        var uuid = databaseNameToUuid[database]
        lock.unlock()

        if uuid == nil && isUuid(database) {
            uuid = database
        }

        if uuid == nil {
            guard let client = getClient() else {
                throw CloudflareD1Error.notConnected
            }

            let databases = try await client.listDatabases()

            lock.lock()
            databaseNameToUuid.removeAll()
            for db in databases {
                databaseNameToUuid[db.name] = db.uuid
            }
            uuid = databaseNameToUuid[database]
            lock.unlock()
        }

        guard let resolvedUuid = uuid else {
            throw CloudflareD1Error(
                message: String(localized: "Database '\(database)' not found")
            )
        }

        lock.lock()
        httpClient?.databaseId = resolvedUuid
        lock.unlock()
    }

    // MARK: - Identifier Quoting

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\0", with: "")
        return result
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS TEXT)"
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN QUERY PLAN \(sql)"
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

    // MARK: - Table Operations

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["DELETE FROM \(quoteIdentifier(table))"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        "DROP \(objectType) IF EXISTS \(quoteIdentifier(name))"
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
        AND name NOT GLOB '_cf_*'
        ORDER BY name
        """
    }

    // MARK: - Transactions

    func beginTransaction() async throws {
        throw CloudflareD1Error(message: String(localized: "Transactions are not supported by Cloudflare D1"))
    }

    func commitTransaction() async throws {
        throw CloudflareD1Error(message: String(localized: "Transactions are not supported by Cloudflare D1"))
    }

    func rollbackTransaction() async throws {
        throw CloudflareD1Error(message: String(localized: "Transactions are not supported by Cloudflare D1"))
    }

    // MARK: - DDL Generation

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let tableName = quoteIdentifier(definition.tableName)
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { d1ColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(d1ForeignKeyDefinition(fk))
        }

        let sql = "CREATE TABLE \(tableName) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        return sql
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        var def = "\(quoteIdentifier(column.name)) \(column.dataType)"
        if !column.isNullable { def += " NOT NULL" }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            def += " DEFAULT \(d1DefaultValue(defaultValue))"
        }
        return "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(def)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        let uniqueStr = index.isUnique ? "UNIQUE " : ""
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        return "CREATE \(uniqueStr)INDEX \(quoteIdentifier(index.name)) ON \(quoteIdentifier(table)) (\(cols))"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX IF EXISTS \(quoteIdentifier(indexName))"
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        d1ColumnDefinition(column, inlinePK: column.isPrimaryKey)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        let uniqueStr = index.isUnique ? "UNIQUE " : ""
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let onClause = tableName.map { " ON \(quoteIdentifier($0))" } ?? ""
        return "CREATE \(uniqueStr)INDEX \(quoteIdentifier(index.name))\(onClause) (\(cols))"
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        d1ForeignKeyDefinition(fk)
    }

    // MARK: - Private Helpers

    private func d1ColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
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
            def += " DEFAULT \(d1DefaultValue(defaultValue))"
        }
        return def
    }

    private func d1DefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_DATE" || upper == "CURRENT_TIME"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    private func d1ForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
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

    private func getClient() -> D1HttpClient? {
        lock.lock()
        defer { lock.unlock() }
        return httpClient
    }

    private func isUuid(_ string: String) -> Bool {
        let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        return string.range(of: uuidPattern, options: .regularExpression) != nil
    }

    private func mapRawResult(_ payload: D1RawResultPayload, executionTime: TimeInterval) -> PluginQueryResult {
        let columns = payload.results.columns ?? []
        let rawRows = payload.results.rows ?? []

        var rows: [[String?]] = []
        var truncated = false

        for rawRow in rawRows {
            if rows.count >= PluginRowLimits.defaultMax {
                truncated = true
                break
            }
            let row = rawRow.map(\.stringValue)
            rows.append(row)
        }

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: columns.map { _ in "" },
            rows: rows,
            rowsAffected: payload.meta?.changes ?? 0,
            executionTime: executionTime,
            isTruncated: truncated
        )
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
        var charIndex = 0
        let chars = Array(formatted)

        while charIndex < chars.count {
            let char = chars[charIndex]

            if char == "(" {
                depth += 1
                result.append(char)
            } else if char == ")" {
                depth -= 1
                result.append(char)
            } else if char == "," && depth == 1 {
                result.append(",\n  ")
                charIndex += 1
                while charIndex < chars.count && chars[charIndex].isWhitespace {
                    charIndex += 1
                }
                charIndex -= 1
            } else {
                result.append(char)
            }

            charIndex += 1
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
