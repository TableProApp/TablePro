//
//  LibSQLPluginDriver.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

// MARK: - Error

private struct LibSQLError: Error, PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }

    static let notConnected = LibSQLError(message: String(localized: "Not connected to database"))
}

// MARK: - Plugin Driver

final class LibSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var httpClient: HranaHttpClient?
    private var _serverVersion: String?
    private let lock = NSLock()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSQLPluginDriver")

    var serverVersion: String? {
        lock.lock()
        defer { lock.unlock() }
        return _serverVersion
    }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var parameterStyle: ParameterStyle { .questionMark }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .alterTableDDL,
            .foreignKeyToggle,
            .truncateTable,
            .cancelQuery,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection

    func connect() async throws {
        guard let rawUrl = config.additionalFields["databaseUrl"], !rawUrl.isEmpty else {
            throw LibSQLError(message: String(localized: "Database URL is required"))
        }

        let normalized = HranaHttpClient.normalizeUrl(rawUrl)
        guard let baseUrl = URL(string: normalized) else {
            throw LibSQLError(message: String(localized: "Invalid database URL"))
        }

        let token = config.password
        let authToken: String? = token.isEmpty ? nil : token

        let client = HranaHttpClient(baseUrl: baseUrl, authToken: authToken)
        client.createSession()

        do {
            let libsqlVersion = try? await client.execute(sql: "SELECT libsql_version()")
            let sqliteVersion = try await client.execute(sql: "SELECT sqlite_version()")
            let version = libsqlVersion?.rows.first?.first?.stringValue
                ?? sqliteVersion.rows.first?.first?.stringValue
                ?? "libSQL"

            lock.lock()
            _serverVersion = version
            lock.unlock()
        } catch {
            client.invalidateSession()
            Self.logger.error("Connection test failed: \(error.localizedDescription)")
            throw LibSQLError(message: String(localized: "Failed to connect to libSQL database"))
        }

        lock.lock()
        httpClient = client
        lock.unlock()

        Self.logger.debug("Connected to libSQL database: \(normalized)")
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
            throw LibSQLError.notConnected
        }

        let startTime = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await client.execute(sql: trimmed)
        let executionTime = Date().timeIntervalSince(startTime)
        return mapExecuteResult(result, executionTime: executionTime)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        guard let client = getClient() else {
            throw LibSQLError.notConnected
        }

        let startTime = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let stringArgs: [String?] = parameters.map { param -> String? in
            switch param {
            case .null: return nil
            case .text(let s): return s
            case .bytes(let d): return "X'" + d.map { String(format: "%02X", $0) }.joined() + "'"
            }
        }
        let result = try await client.execute(sql: trimmed, args: stringArgs)
        let executionTime = Date().timeIntervalSince(startTime)
        return mapExecuteResult(result, executionTime: executionTime)
    }

    func executeBatch(queries: [String]) async throws -> [PluginQueryResult] {
        guard let client = getClient() else {
            throw LibSQLError.notConnected
        }

        let startTime = Date()
        let statements = queries.map { (sql: $0, args: [] as [String?]) }
        let results = try await client.executeBatch(statements: statements)
        let elapsed = Date().timeIntervalSince(startTime)

        return results.map { result in
            mapExecuteResult(result, executionTime: elapsed / Double(results.count))
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
            throw LibSQLError.notConnected
        }

        let result = try await client.execute(sql: query)

        let columns = result.cols.map(\.name)
        let columnTypeNames = result.cols.map { $0.decltype ?? "" }
        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columnTypeNames,
            estimatedRowCount: nil
        )))

        if !result.rows.isEmpty {
            let rows = result.rows.map { rawRow in rawRow.map(\.stringValue) }
            continuation.yield(.rows(rows))
        }

        continuation.finish()
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let query = """
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view')
            AND name NOT LIKE 'sqlite_%'
            AND name NOT GLOB 'libsql_*'
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
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name NOT GLOB 'libsql_*'
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
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name NOT GLOB 'libsql_*'
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
            throw LibSQLError(message: "Failed to fetch DDL for table '\(table)'")
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
            throw LibSQLError(message: "Failed to fetch definition for view '\(view)'")
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
            engine: "libSQL"
        )
    }

    // MARK: - Database Operations

    func fetchDatabases() async throws -> [String] {
        ["main"]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func dropDatabase(name: String) async throws {
        throw LibSQLError(message: String(localized: "Dropping databases is not supported"))
    }

    func switchDatabase(to database: String) async throws {
        throw LibSQLError(message: String(localized: "Switching databases is not supported"))
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
        AND name NOT GLOB 'libsql_*'
        ORDER BY name
        """
    }

    // MARK: - Transactions

    func beginTransaction() async throws {
        throw LibSQLError(message: String(localized: "Transactions are not supported in this mode"))
    }

    func commitTransaction() async throws {
        throw LibSQLError(message: String(localized: "Transactions are not supported in this mode"))
    }

    func rollbackTransaction() async throws {
        throw LibSQLError(message: String(localized: "Transactions are not supported in this mode"))
    }

    // MARK: - DDL Generation

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let tableName = quoteIdentifier(definition.tableName)
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { columnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(foreignKeyDefinition(fk))
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
            def += " DEFAULT \(sqlDefaultValue(defaultValue))"
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
        columnDefinition(column, inlinePK: column.isPrimaryKey)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        let uniqueStr = index.isUnique ? "UNIQUE " : ""
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let onClause = tableName.map { " ON \(quoteIdentifier($0))" } ?? ""
        return "CREATE \(uniqueStr)INDEX \(quoteIdentifier(index.name))\(onClause) (\(cols))"
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        foreignKeyDefinition(fk)
    }

    // MARK: - Private Helpers

    private func columnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
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
            def += " DEFAULT \(sqlDefaultValue(defaultValue))"
        }
        return def
    }

    private func sqlDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_DATE" || upper == "CURRENT_TIME"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    private func foreignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
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

    private func getClient() -> HranaHttpClient? {
        lock.lock()
        defer { lock.unlock() }
        return httpClient
    }

    private func mapExecuteResult(_ result: HranaExecuteResult, executionTime: TimeInterval) -> PluginQueryResult {
        let columns = result.cols.map(\.name)
        let columnTypeNames = result.cols.map { $0.decltype ?? "" }

        var rows: [[PluginCellValue]] = []
        var truncated = false

        for rawRow in result.rows {
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }
            let row = rawRow.map(\.stringValue).map(PluginCellValue.fromOptional)
            rows.append(row)
        }

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: result.affectedRowCount,
            executionTime: executionTime,
            isTruncated: truncated
        )
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
