//
//  SnowflakePluginDriver.swift
//  SnowflakeDriverPlugin
//
//  PluginDatabaseDriver implementation backed by SnowflakeConnection.
//

import Foundation
import os
import TableProPluginKit

final class SnowflakePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var _connection: SnowflakeConnection?
    private var _serverVersion: String?
    private var resolvedSchemaCache: [String: String] = [:]
    private var columnTypeCache: [String: [String: String]] = [:]

    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakePluginDriver")

    private var connection: SnowflakeConnection? {
        lock.withLock { _connection }
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    var capabilities: PluginCapabilities {
        [.multiSchema, .transactions, .truncateTable, .cancelQuery, .parameterizedQueries, .alterTableDDL]
    }

    func cancelQuery() throws {
        connection?.cancelAllQueries()
    }

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { lock.withLock { _serverVersion } }
    var currentSchema: String? { connection?.currentSchema }
    var parameterStyle: ParameterStyle { .questionMark }
    var requiresBackslashEscapingInLiterals: Bool { true }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else { return try await execute(query: query) }
        guard let conn = connection else { throw SnowflakeError.notConnected }
        let startTime = Date()
        let result = try await conn.query(query, parameters: parameters)
        return PluginQueryResult(
            columns: result.columns.map(\.name),
            columnTypeNames: result.columns.map(SnowflakeTypeMapper.displayType),
            rows: result.rows.map { row in row.map(Self.cellValue) },
            rowsAffected: result.affectedRows,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: result.isTruncated,
            statusMessage: result.statusMessage
        )
    }

    // MARK: - Lifecycle

    func connect() async throws {
        let conn = SnowflakeConnectionRegistry.shared.acquire(config: config)
        do {
            try await conn.connectIfNeeded()
        } catch {
            SnowflakeConnectionRegistry.shared.release(conn)
            throw error
        }
        lock.withLock { _connection = conn }

        if let result = try? await conn.query("SELECT CURRENT_VERSION()"),
           let first = result.rows.first?.first, case .text(let version) = first {
            lock.withLock { _serverVersion = "Snowflake \(version)" }
        } else {
            lock.withLock { _serverVersion = "Snowflake" }
        }
    }

    func disconnect() {
        let conn: SnowflakeConnection? = lock.withLock {
            let current = _connection
            _connection = nil
            return current
        }
        if let conn {
            SnowflakeConnectionRegistry.shared.release(conn)
        }
    }

    func ping() async throws {
        guard let conn = connection else { throw SnowflakeError.notConnected }
        try await conn.ping()
    }

    // MARK: - Transactions

    func beginTransaction() async throws { _ = try await execute(query: "BEGIN") }
    func commitTransaction() async throws { _ = try await execute(query: "COMMIT") }
    func rollbackTransaction() async throws { _ = try await execute(query: "ROLLBACK") }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        guard let conn = connection else { throw SnowflakeError.notConnected }
        let startTime = Date()
        let result = try await conn.query(query)
        let executionTime = Date().timeIntervalSince(startTime)

        if result.columns.isEmpty {
            return PluginQueryResult(
                columns: ["status"],
                columnTypeNames: ["TEXT"],
                rows: [[.text("Statement executed")]],
                rowsAffected: result.affectedRows,
                executionTime: executionTime,
                statusMessage: result.statusMessage
            )
        }

        return PluginQueryResult(
            columns: result.columns.map(\.name),
            columnTypeNames: result.columns.map(SnowflakeTypeMapper.displayType),
            rows: result.rows.map { row in row.map(Self.cellValue) },
            rowsAffected: result.affectedRows,
            executionTime: executionTime,
            isTruncated: result.isTruncated,
            statusMessage: result.statusMessage
        )
    }

    // MARK: - Schema Navigation

    func fetchDatabases() async throws -> [String] {
        let result = try await rawQuery("SHOW DATABASES")
        return namedValues(in: result, column: "name")
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await rawQuery("SHOW SCHEMAS")
        return namedValues(in: result, column: "name")
    }

    func switchDatabase(to database: String) async throws {
        guard let conn = connection else { throw SnowflakeError.notConnected }
        try await conn.switchDatabase(to: database)
        lock.withLock {
            resolvedSchemaCache.removeAll()
            columnTypeCache.removeAll()
        }
    }

    func switchSchema(to schema: String) async throws {
        guard let conn = connection else { throw SnowflakeError.notConnected }
        try await conn.switchSchema(to: schema)
        lock.withLock {
            resolvedSchemaCache.removeAll()
            columnTypeCache.removeAll()
        }
    }

    // MARK: - Session Contexts

    func fetchSessionContexts() async throws -> [PluginSessionContext]? {
        guard let conn = connection else { return nil }
        var contexts: [PluginSessionContext] = []
        if let warehouses = try? await rawQuery("SHOW WAREHOUSES"),
           let nameIndex = columnIndex(of: "name", in: warehouses) {
            contexts.append(PluginSessionContext(
                id: "warehouse",
                label: String(localized: "Warehouse"),
                iconName: "building.columns",
                currentValue: conn.currentWarehouse,
                availableValues: warehouses.rows.compactMap { Self.text($0, nameIndex) }
            ))
        }
        if let roles = try? await rawQuery("SHOW ROLES"),
           let nameIndex = columnIndex(of: "name", in: roles) {
            contexts.append(PluginSessionContext(
                id: "role",
                label: String(localized: "Role"),
                iconName: "person.badge.key",
                currentValue: conn.currentRole,
                availableValues: roles.rows.compactMap { Self.text($0, nameIndex) }
            ))
        }
        return contexts.isEmpty ? nil : contexts
    }

    func switchSessionContext(id: String, to value: String) async throws {
        guard let conn = connection else { throw SnowflakeError.notConnected }
        switch id {
        case "warehouse":
            _ = try await conn.query("USE WAREHOUSE \(quoteIdentifier(value))")
        case "role":
            _ = try await conn.query("USE ROLE \(quoteIdentifier(value))")
            lock.withLock {
                resolvedSchemaCache.removeAll()
                columnTypeCache.removeAll()
            }
        default:
            break
        }
    }

    // MARK: - Database Management

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(
            fields: [
                PluginCreateDatabaseFormSpec.Field(
                    id: "retentionDays",
                    label: String(localized: "Time Travel Retention"),
                    kind: .picker(
                        options: [
                            .init(value: "1", label: String(localized: "1 day (default)")),
                            .init(value: "0", label: String(localized: "Disabled")),
                            .init(value: "7", label: String(localized: "7 days")),
                            .init(value: "14", label: String(localized: "14 days")),
                            .init(value: "30", label: String(localized: "30 days")),
                            .init(value: "90", label: String(localized: "90 days"))
                        ],
                        defaultValue: "1"
                    )
                )
            ],
            footnote: String(localized: "Retention beyond 1 day requires Enterprise edition.")
        )
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        var sql = "CREATE DATABASE \(quoteIdentifier(request.name))"
        if let retention = request.values["retentionDays"], let days = Int(retention), days != 1 {
            sql += " DATA_RETENTION_TIME_IN_DAYS = \(days)"
        }
        _ = try await rawQuery(sql)
    }

    func dropDatabase(name: String) async throws {
        _ = try await rawQuery("DROP DATABASE IF EXISTS \(quoteIdentifier(name))")
    }

    // MARK: - Schema Introspection

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let database = connection?.currentDatabase
        let targetSchema = schema ?? connection?.currentSchema
        guard let database, let targetSchema else { return [] }

        let result: SnowflakeQueryResult
        do {
            result = try await rawQuery(SnowflakeSchemaQueries.showObjects(database: database, schema: targetSchema))
        } catch let error as SnowflakeError where error.indicatesInaccessibleObject {
            Self.logger.debug("Schema \(targetSchema, privacy: .public) is visible but not enumerable; showing it empty")
            return []
        }
        guard let nameIndex = columnIndex(of: "name", in: result) else { return [] }
        let kindIndex = columnIndex(of: "kind", in: result)
        return result.rows.compactMap { row in
            guard let name = Self.text(row, nameIndex) else { return nil }
            let kind = kindIndex.flatMap { Self.text(row, $0) } ?? "TABLE"
            return PluginTableInfo(
                name: name,
                type: SnowflakeSchemaQueries.objectType(forKind: kind),
                schema: targetSchema
            )
        }.sorted { $0.name < $1.name }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let database = connection?.currentDatabase
        let targetSchema = schema ?? connection?.currentSchema
        guard let database, let targetSchema else { return [:] }

        let primaryKeys = await primaryKeysBySchema(database: database, schema: targetSchema)
        let result: SnowflakeQueryResult
        do {
            result = try await rawQuery(SnowflakeSchemaQueries.bulkColumns(database: database, schema: targetSchema))
        } catch let error as SnowflakeError where error.indicatesInaccessibleObject {
            return [:]
        }

        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let table = Self.text(row, 0), let name = Self.text(row, 1) else { continue }
            let column = PluginColumnInfo(
                name: name,
                dataType: Self.text(row, 2) ?? "TEXT",
                isNullable: (Self.text(row, 3) ?? "YES").uppercased() == "YES",
                isPrimaryKey: primaryKeys[table]?.contains(name.uppercased()) == true,
                defaultValue: Self.text(row, 4),
                comment: Self.text(row, 5)
            )
            columnsByTable[table, default: []].append(column)
        }
        for (table, columns) in columnsByTable {
            cacheColumnTypes(table: table, schema: targetSchema, columns: columns)
        }
        return columnsByTable
    }

    private func primaryKeysBySchema(database: String, schema: String) async -> [String: Set<String>] {
        guard let result = try? await rawQuery(
            SnowflakeSchemaQueries.showPrimaryKeysInSchema(database: database, schema: schema)
        ) else { return [:] }
        guard let tableIndex = columnIndex(of: "table_name", in: result),
              let columnIndexInResult = columnIndex(of: "column_name", in: result) else { return [:] }

        var keys: [String: Set<String>] = [:]
        for row in result.rows {
            guard let table = Self.text(row, tableIndex),
                  let column = Self.text(row, columnIndexInResult) else { continue }
            keys[table, default: []].insert(column.uppercased())
        }
        return keys
    }

    private func columnIndex(of name: String, in result: SnowflakeQueryResult) -> Int? {
        result.columns.firstIndex { $0.name.lowercased() == name.lowercased() }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let database = connection?.currentDatabase
        var targetSchema = schema ?? connection?.currentSchema
        if targetSchema == nil, let database {
            targetSchema = await resolveSchema(for: table, database: database)
        }
        Self.logger.debug(
            "fetchColumns table=\(table, privacy: .public) schemaParam=\(schema ?? "nil", privacy: .public) currentSchema=\(self.connection?.currentSchema ?? "nil", privacy: .public) currentDatabase=\(database ?? "nil", privacy: .public)"
        )
        guard let database, let targetSchema else { return [] }

        let primaryKeys = try await fetchPrimaryKeyColumns(table: table, schema: targetSchema, database: database)

        let sql = """
            SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COMMENT,
                   NUMERIC_PRECISION, NUMERIC_SCALE, CHARACTER_MAXIMUM_LENGTH
            FROM \(quoteIdentifier(database)).INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = '\(escapeStringLiteral(targetSchema))'
              AND TABLE_NAME = '\(escapeStringLiteral(table))'
            ORDER BY ORDINAL_POSITION
            """
        let result = try await rawQuery(sql)
        Self.logger.debug(
            "fetchColumns table=\(table, privacy: .public) schema=\(targetSchema, privacy: .public) database=\(database, privacy: .public) rows=\(result.rows.count, privacy: .public)"
        )
        let columns = result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = Self.text(row, 0) else { return nil }
            let dataType = Self.text(row, 1) ?? "TEXT"
            let nullable = (Self.text(row, 2) ?? "YES").uppercased() == "YES"
            let defaultValue = Self.text(row, 3)
            let comment = Self.text(row, 4)
            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: nullable,
                isPrimaryKey: primaryKeys.contains(name.uppercased()),
                defaultValue: defaultValue,
                comment: comment
            )
        }
        cacheColumnTypes(table: table, schema: targetSchema, columns: columns)
        return columns
    }

    func cacheColumnTypes(table: String, schema: String?, columns: [PluginColumnInfo]) {
        let key = columnTypeCacheKey(table: table, schema: schema)
        let types = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0.dataType) })
        lock.withLock { columnTypeCache[key] = types }
    }

    func columnTypeNames(for table: String, columns: [String]) -> [String] {
        let key = columnTypeCacheKey(table: table, schema: nil)
        let types = lock.withLock { columnTypeCache[key] } ?? [:]
        return columns.map { types[$0] ?? "TEXT" }
    }

    private func columnTypeCacheKey(table: String, schema: String?) -> String {
        "\((schema ?? connection?.currentSchema) ?? "").\(table)"
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let database = connection?.currentDatabase
        let targetSchema = schema ?? connection?.currentSchema
        guard let database, let targetSchema else { return [] }

        var indexes: [PluginIndexInfo] = []

        let primaryKeys = try await fetchPrimaryKeyColumnsOrdered(table: table, schema: targetSchema, database: database)
        if !primaryKeys.isEmpty {
            indexes.append(PluginIndexInfo(
                name: "PRIMARY KEY",
                columns: primaryKeys,
                isUnique: true,
                isPrimary: true,
                type: "CONSTRAINT"
            ))
        }

        if let clusterColumns = await clusteringKeyColumns(table: table, schema: targetSchema, database: database),
           !clusterColumns.isEmpty {
            indexes.append(PluginIndexInfo(
                name: "CLUSTERING KEY",
                columns: clusterColumns,
                isUnique: false,
                isPrimary: false,
                type: "CLUSTERING"
            ))
        }

        return indexes
    }

    private func fetchPrimaryKeyColumnsOrdered(table: String, schema: String, database: String) async throws -> [String] {
        guard let result = try? await rawQuery(
            SnowflakeSchemaQueries.showPrimaryKeysInTable(database: database, schema: schema, table: table)
        ) else { return [] }
        guard let columnIdx = columnIndex(of: "column_name", in: result) else { return [] }
        let sequenceIdx = columnIndex(of: "key_sequence", in: result)
        let entries = result.rows.compactMap { row -> (column: String, sequence: Int)? in
            guard let column = Self.text(row, columnIdx) else { return nil }
            let sequence = sequenceIdx.flatMap { Self.text(row, $0) }.flatMap(Int.init) ?? 0
            return (column, sequence)
        }
        return entries.sorted { $0.sequence < $1.sequence }.map(\.column)
    }

    private func clusteringKeyColumns(table: String, schema: String, database: String) async -> [String]? {
        guard let result = try? await rawQuery(
            SnowflakeSchemaQueries.showTablesLike(database: database, schema: schema, table: table)
        ) else { return nil }
        guard let clusterIdx = columnIndex(of: "cluster_by", in: result),
              let row = result.rows.first,
              let clusterBy = Self.text(row, clusterIdx),
              !clusterBy.isEmpty else { return nil }
        return SnowflakeSchemaQueries.parseClusterBy(clusterBy)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let database = connection?.currentDatabase
        let targetSchema = schema ?? connection?.currentSchema
        guard let database, let targetSchema else { return [] }

        guard let result = try? await rawQuery(
            SnowflakeSchemaQueries.showImportedKeys(database: database, schema: targetSchema, table: table)
        ) else { return [] }

        guard let fkColumnIdx = columnIndex(of: "fk_column_name", in: result),
              let pkTableIdx = columnIndex(of: "pk_table_name", in: result),
              let pkColumnIdx = columnIndex(of: "pk_column_name", in: result) else { return [] }
        let fkNameIdx = columnIndex(of: "fk_name", in: result)
        let pkSchemaIdx = columnIndex(of: "pk_schema_name", in: result)

        return result.rows.compactMap { row in
            guard let column = Self.text(row, fkColumnIdx),
                  let referencedTable = Self.text(row, pkTableIdx),
                  let referencedColumn = Self.text(row, pkColumnIdx) else { return nil }
            return PluginForeignKeyInfo(
                name: fkNameIdx.flatMap { Self.text(row, $0) } ?? "FK_\(column)",
                column: column,
                referencedTable: referencedTable,
                referencedColumn: referencedColumn,
                referencedSchema: pkSchemaIdx.flatMap { Self.text(row, $0) }
            )
        }
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let database = connection?.currentDatabase
        var targetSchema = schema ?? connection?.currentSchema
        if targetSchema == nil, let database, let resolved = await resolveSchema(for: table, database: database) {
            targetSchema = resolved
        }
        guard let database, let targetSchema else { return nil }
        let sql = """
            SELECT ROW_COUNT
            FROM \(quoteIdentifier(database)).INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '\(escapeStringLiteral(targetSchema))'
              AND TABLE_NAME = '\(escapeStringLiteral(table))'
            """
        let result = try await rawQuery(sql)
        guard let value = Self.text(result.rows.first ?? [], 0) else { return nil }
        return Int(value)
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let database = connection?.currentDatabase
        let targetSchema = schema ?? connection?.currentSchema
        guard let database, let targetSchema else {
            return PluginTableMetadata(tableName: table)
        }
        let sql = """
            SELECT ROW_COUNT, BYTES, COMMENT
            FROM \(quoteIdentifier(database)).INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '\(escapeStringLiteral(targetSchema))'
              AND TABLE_NAME = '\(escapeStringLiteral(table))'
            """
        let result = try await rawQuery(sql)
        let row = result.rows.first ?? []
        let rowCount = Self.text(row, 0).flatMap { Int64($0) }
        let bytes = Self.text(row, 1).flatMap { Int64($0) }
        let comment = Self.text(row, 2)
        return PluginTableMetadata(
            tableName: table,
            dataSize: bytes,
            totalSize: bytes,
            rowCount: rowCount,
            comment: comment?.isEmpty == true ? nil : comment
        )
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let isSystem = SnowflakePlugin.systemDatabaseNames.contains(database.uppercased())
        return PluginDatabaseMetadata(name: database, isSystemDatabase: isSystem)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await ddl(objectType: "TABLE", name: table, schema: schema)
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        try await ddl(objectType: "VIEW", name: view, schema: schema)
    }

    // MARK: - SQL Generation Helpers

    func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    func castColumnToText(_ column: String) -> String {
        "TO_VARCHAR(\(column))"
    }

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN USING TEXT \(sql)"
    }

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func defaultExportQuery(table: String) -> String? {
        defaultExportQuery(table: table, schema: nil)
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        "SELECT * FROM \(qualifiedName(table: table, schema: schema))"
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["TRUNCATE TABLE \(qualifiedName(table: table, schema: schema))"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        let suffix = cascade ? " CASCADE" : ""
        return "DROP \(objectType.uppercased()) IF EXISTS \(qualifiedName(table: name, schema: schema))\(suffix)"
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    guard let conn = self.connection else { throw SnowflakeError.notConnected }
                    let trimmed = query.replacingOccurrences(of: ";\\s*\\z", with: "", options: .regularExpression)
                    let streamed = try await conn.queryStreamed(trimmed)
                    continuation.yield(.header(PluginStreamHeader(
                        columns: streamed.columns.map(\.name),
                        columnTypeNames: streamed.columns.map(SnowflakeTypeMapper.displayType),
                        estimatedRowCount: streamed.estimatedRowCount
                    )))
                    if !streamed.inlineRows.isEmpty {
                        continuation.yield(.rows(streamed.inlineRows.map { row in row.map(Self.cellValue) }))
                    }
                    for try await batch in streamed.batches {
                        continuation.yield(.rows(batch.map { row in row.map(Self.cellValue) }))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Private Helpers

    func qualifiedName(table: String, schema: String?) -> String {
        qualifiedName(table: table, resolvedSchema: schema ?? connection?.currentSchema)
    }

    private func qualifiedNameResolvingSchema(table: String, schema: String?) async -> String {
        var targetSchema = schema ?? connection?.currentSchema
        if targetSchema == nil, let database = connection?.currentDatabase {
            targetSchema = await resolveSchema(for: table, database: database)
        }
        return qualifiedName(table: table, resolvedSchema: targetSchema)
    }

    private func qualifiedName(table: String, resolvedSchema targetSchema: String?) -> String {
        if let database = connection?.currentDatabase, let targetSchema {
            return "\(quoteIdentifier(database)).\(quoteIdentifier(targetSchema)).\(quoteIdentifier(table))"
        }
        if let targetSchema {
            return "\(quoteIdentifier(targetSchema)).\(quoteIdentifier(table))"
        }
        return quoteIdentifier(table)
    }

    private func ddl(objectType: String, name: String, schema: String?) async throws -> String {
        let fqn = await qualifiedNameResolvingSchema(table: name, schema: schema)
        let sql = "SELECT GET_DDL('\(objectType)', '\(escapeStringLiteral(fqn))', true)"
        let result = try await rawQuery(sql)
        guard let ddl = Self.text(result.rows.first ?? [], 0) else {
            throw SnowflakeError.invalidResponse("No DDL returned for \(name)")
        }
        return ddl
    }

    private func fetchPrimaryKeyColumns(table: String, schema: String, database: String) async throws -> Set<String> {
        let fqn = "\(quoteIdentifier(database)).\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
        guard let result = try? await rawQuery("SHOW PRIMARY KEYS IN TABLE \(fqn)") else {
            return []
        }
        guard let columnIndex = result.columns.firstIndex(where: { $0.name.lowercased() == "column_name" }) else {
            return []
        }
        var keys: Set<String> = []
        for row in result.rows {
            if let value = Self.text(row, columnIndex) {
                keys.insert(value.uppercased())
            }
        }
        return keys
    }

    /// Resolves the schema for a table when the caller didn't provide one and no
    /// schema is active — common for hierarchical browsing where app-side calls
    /// are schema-unaware. Prefers a unique INFORMATION_SCHEMA match, then PUBLIC.
    private func resolveSchema(for table: String, database: String) async -> String? {
        if let current = connection?.currentSchema { return current }
        let cacheKey = "\(database).\(table)"
        if let cached = lock.withLock({ resolvedSchemaCache[cacheKey] }) { return cached }

        let sql = """
            SELECT TABLE_SCHEMA
            FROM \(quoteIdentifier(database)).INFORMATION_SCHEMA.TABLES
            WHERE TABLE_NAME = '\(escapeStringLiteral(table))'
            """
        guard let result = try? await rawQuery(sql) else { return nil }
        let schemas = result.rows.compactMap { Self.text($0, 0) }
        let resolved = schemas.count == 1
            ? schemas[0]
            : (schemas.first { $0 == "PUBLIC" } ?? schemas.first)
        if let resolved {
            lock.withLock { resolvedSchemaCache[cacheKey] = resolved }
            Self.logger.debug("resolveSchema table=\(table, privacy: .public) -> \(resolved, privacy: .public) (candidates=\(schemas.count, privacy: .public))")
        }
        return resolved
    }

    private func rawQuery(_ sql: String) async throws -> SnowflakeQueryResult {
        guard let conn = connection else { throw SnowflakeError.notConnected }
        return try await conn.query(sql)
    }

    private func namedValues(in result: SnowflakeQueryResult, column: String) -> [String] {
        guard let index = result.columns.firstIndex(where: { $0.name.lowercased() == column.lowercased() }) else {
            return []
        }
        return result.rows.compactMap { Self.text($0, index) }
    }

    private static func cellValue(_ box: PluginCellValueBox) -> PluginCellValue {
        switch box {
        case .null: return .null
        case .text(let value): return .text(value)
        }
    }

    private static func text(_ row: [PluginCellValueBox], _ index: Int) -> String? {
        guard index >= 0, index < row.count else { return nil }
        if case .text(let value) = row[index] { return value }
        return nil
    }
}
