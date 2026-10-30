//
//  LibSQLPluginDriver.swift
//  TablePro
//

import CSQLite
import Foundation
import os
import TableProPluginKit

// MARK: - Plugin Driver

final class LibSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private enum Backend {
        case remote(HranaHttpClient)
        case local(SQLiteLocalBackend)
    }

    private let config: DriverConnectionConfig
    private let localDatabaseRuntime: any LibSQLLocalDatabaseRuntime
    private var backend: Backend?
    private var _serverVersion: String?
    private var _connectionWarning: String?
    nonisolated(unsafe) private var _dbHandleForInterrupt: OpaquePointer?
    private let lock = NSLock()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LibSQLPluginDriver")

    var serverVersion: String? {
        lock.lock()
        defer { lock.unlock() }
        return _serverVersion
    }
    var connectionWarning: String? {
        lock.lock()
        defer { lock.unlock() }
        return _connectionWarning
    }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { isLocalMode }
    var currentSchema: String? { nil }
    var parameterStyle: ParameterStyle { .questionMark }

    var capabilities: PluginCapabilities {
        var base: PluginCapabilities = [
            .parameterizedQueries,
            .alterTableDDL,
            .truncateTable,
            .cancelQuery,
            .schemaCompare,
            .dataCompare,
        ]
        if isLocalMode {
            base.insert(.transactions)
            base.insert(.batchExecute)
            base.insert(.foreignKeyToggle)
        }
        return base
    }

    init(
        config: DriverConnectionConfig,
        localDatabaseRuntime: any LibSQLLocalDatabaseRuntime
    ) {
        self.config = config
        self.localDatabaseRuntime = localDatabaseRuntime
    }

    private var isLocalMode: Bool {
        config.additionalFields["libsqlMode"] == "local"
    }

    // MARK: - Connection

    func connect() async throws {
        if isLocalMode {
            try await connectLocal()
        } else {
            try await connectRemote()
        }
    }

    private func connectLocal() async throws {
        guard let rawPath = config.additionalFields["libsqlFilePath"], !rawPath.isEmpty else {
            throw LibSQLError(message: String(localized: "Database file path is required"))
        }

        let path = expandPath(rawPath)
        if !FileManager.default.fileExists(atPath: path) {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let extensions = try LoadableExtensionList.decode(config.additionalFields[LoadableExtensionList.fieldId])
        let attachments = try AttachedDatabaseList.decode(config.additionalFields[AttachedDatabaseList.fieldId])
        let localBackend = SQLiteLocalBackend(runtime: localDatabaseRuntime)
        try await localBackend.open(path: path, loading: extensions)
        let rawHandle = await localBackend.dbHandleForInterrupt
        let versionResult = try await localBackend.executeQuery("SELECT sqlite_version()")
        let version = versionResult.rows.first?.first?.asText ?? "SQLite"
        let failures = await AttachedDatabaseAttacher.attach(attachments) { database in
            _ = try await localBackend.executeParameterizedQuery(
                "ATTACH DATABASE ? AS ?",
                parameters: [.text(database.expandedPath), .text(database.name)]
            )
        }

        lock.withLock {
            _dbHandleForInterrupt = rawHandle != 0 ? OpaquePointer(bitPattern: rawHandle) : nil
            _serverVersion = version
            _connectionWarning = AttachedDatabaseAttacher.warning(for: failures)
            backend = .local(localBackend)
        }

        Self.logger.debug("Connected to local libSQL database file")
    }

    private func connectRemote() async throws {
        guard let rawUrl = config.additionalFields["databaseUrl"], !rawUrl.isEmpty else {
            throw LibSQLError(message: String(localized: "Database URL is required"))
        }

        let normalized = HranaHttpClient.normalizeUrl(rawUrl)
        guard let baseUrl = URL(string: normalized) else {
            throw LibSQLError(message: String(localized: "Invalid database URL"))
        }

        let token = config.password
        let authToken: String? = token.isEmpty ? nil : token

        let connectTimeoutMilliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout.sessionBootstrapRequestTimeout * 1_000)
        )
        let deadline = PluginConnectDeadline(milliseconds: connectTimeoutMilliseconds)
        let client = HranaHttpClient(baseUrl: baseUrl, authToken: authToken)
        client.createSession(connectTimeout: TimeInterval(connectTimeoutMilliseconds) / 1_000)

        do {
            let libsqlVersion = try? await client.execute(
                sql: "SELECT libsql_version()",
                requestTimeout: deadline.remainingSeconds()
            )
            let sqliteVersion = try await client.execute(
                sql: "SELECT sqlite_version()",
                requestTimeout: deadline.remainingSeconds()
            )
            let version = libsqlVersion?.rows.first?.first?.stringValue
                ?? sqliteVersion.rows.first?.first?.stringValue
                ?? "libSQL"

            lock.withLock { _serverVersion = version }
        } catch {
            client.invalidateSession()
            Self.logger.error("Connection test failed: \(error.localizedDescription)")
            throw LibSQLError(message: String(localized: "Failed to connect to libSQL database"))
        }

        lock.withLock { backend = .remote(client) }

        Self.logger.debug("Connected to libSQL database: \(normalized)")
    }

    func disconnect() {
        lock.lock()
        let current = backend
        backend = nil
        _dbHandleForInterrupt = nil
        lock.unlock()

        switch current {
        case .remote(let client):
            client.invalidateSession()
        case .local(let localBackend):
            Task { await localBackend.close() }
        case nil:
            break
        }
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        switch getBackend() {
        case .remote(let client):
            let startTime = Date()
            let result = try await client.execute(sql: trimmed)
            let executionTime = Date().timeIntervalSince(startTime)
            return mapExecuteResult(result, executionTime: executionTime)
        case .local(let localBackend):
            let raw = try await localBackend.executeQuery(trimmed)
            return mapLocalResult(raw)
        case nil:
            throw LibSQLError.notConnected
        }
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        switch getBackend() {
        case .remote(let client):
            let startTime = Date()
            let result = try await client.execute(sql: trimmed, args: parameters)
            let executionTime = Date().timeIntervalSince(startTime)
            return mapExecuteResult(result, executionTime: executionTime)
        case .local(let localBackend):
            let raw = try await localBackend.executeParameterizedQuery(trimmed, parameters: parameters)
            return mapLocalResult(raw)
        case nil:
            throw LibSQLError.notConnected
        }
    }

    func executeBatch(queries: [String]) async throws -> [PluginQueryResult] {
        switch getBackend() {
        case .remote(let client):
            let startTime = Date()
            let statements = queries.map { HranaStatement(sql: $0) }
            let results = try await client.executeBatch(statements: statements)
            let elapsed = Date().timeIntervalSince(startTime)

            return results.map { result in
                mapExecuteResult(result, executionTime: elapsed / Double(results.count))
            }
        case .local(let localBackend):
            var results: [PluginQueryResult] = []
            for query in queries {
                let raw = try await localBackend.executeQuery(query)
                results.append(mapLocalResult(raw))
            }
            return results
        case nil:
            throw LibSQLError.notConnected
        }
    }

    func cancelQuery() throws {
        lock.lock()
        let current = backend
        if case .local(let localBackend) = current {
            localBackend.cancelBusyWait()
            if let interruptHandle = _dbHandleForInterrupt {
                sqlite3_interrupt(interruptHandle)
            }
        }
        lock.unlock()

        if case .remote(let client) = current {
            client.cancelAll()
        }
    }

    var hasRetriedLocalBusyWait: Bool {
        guard case .local(let localBackend) = getBackend() else { return false }
        return localBackend.hasRetriedBusyWait
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        let boundedSeconds = PluginQueryTimeout.boundedSeconds(seconds)
        switch getBackend() {
        case .remote(let client):
            client.setQueryTimeout(boundedSeconds)
        case .local(let localBackend):
            await localBackend.applyBusyTimeout(PluginQueryTimeout.int32Milliseconds(boundedSeconds))
        case nil:
            break
        }
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
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
        switch getBackend() {
        case .remote(let client):
            let result = try await client.execute(sql: query)

            let columns = result.cols.map(\.name)
            let columnTypeNames = result.cols.map { $0.decltype ?? "" }
            continuation.yield(.header(PluginStreamHeader(
                columns: columns,
                columnTypeNames: columnTypeNames,
                estimatedRowCount: nil
            )))

            if !result.rows.isEmpty {
                let rows = result.rows.map { rawRow in
                    rawRow.map(\.stringValue).map(PluginCellValue.fromOptional)
                }
                continuation.yield(.rows(rows))
            }

            continuation.finish()
        case .local(let localBackend):
            try await localBackend.streamQuery(query, continuation: continuation)
        case nil:
            throw LibSQLError.notConnected
        }
    }

    // MARK: - Schema Operations

    /// The databases attached beside a local file. A remote database is one database on the server
    /// and cannot attach anything, so it is not asked.
    func fetchSchemas() async throws -> [String] {
        guard isLocalMode else { return [] }
        let result = try await execute(query: SQLiteMasterQueries.attachedDatabasesQuery)
        return result.rows.compactMap { $0[safe: 0]?.asText }
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let query = """
            SELECT name, type FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
            WHERE type IN ('table', 'view')
            AND name NOT GLOB 'sqlite_*'
            AND name NOT GLOB 'libsql_*'
            ORDER BY name
            """
        let result = try await execute(query: query)
        let attached = SQLiteMasterQueries.attachedSchema(schema)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeString = row[safe: 1]?.asText ?? "table"
            let tableType = typeString.lowercased() == "view" ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType, schema: attached)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeTable = escapeStringLiteral(table)
        let query = "SELECT * FROM pragma_table_info('\(safeTable)'\(SQLiteMasterQueries.pragmaSchemaArgument(schema)))"
        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[1].asText,
                  let dataType = row[2].asText else {
                return nil
            }

            let isNullable = row[3].asText == "0"
            let isPrimaryKey = row[5].asText != nil && row[5].asText != "0"
            let defaultValue = libSQLDefaultValueFromCatalog(row[4].asText)

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
            FROM \(SQLiteMasterQueries.catalogTable(schema: schema)) m,
                 pragma_table_info(m.name\(SQLiteMasterQueries.pragmaSchemaArgument(schema))) p
            WHERE m.type = 'table' AND m.name NOT GLOB 'sqlite_*' AND m.name NOT GLOB 'libsql_*'
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
            let defaultValue = libSQLDefaultValueFromCatalog(row[5].asText)
            let isPrimaryKey = row[6].asText != nil && row[6].asText != "0"

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

    var tableDDLIncludesForeignKeys: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let query = SQLiteForeignKeyGrouping.schemaForeignKeysQuery(schema: schema, excludingTableGlob: "libsql_*")
        return SQLiteForeignKeyGrouping.foreignKeysByTable(schema: schema, fromRows: try await execute(query: query).rows)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let result = try await execute(query: SQLiteIndexCatalog.indexesQuery(table: table, schema: schema))
        return SQLiteIndexCatalog.indexes(fromRows: result.rows)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let result = try await execute(query: SQLiteForeignKeyGrouping.foreignKeysQuery(table: table, schema: schema))
        return SQLiteForeignKeyGrouping.foreignKeys(table: table, schema: schema, fromRows: result.rows)
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await sqliteTriggerList(table: table, schema: schema)
    }

    var supportsTransactionalDDL: Bool { true }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        """
        CREATE TRIGGER \(SQLiteMasterQueries.qualifiedTable("trigger_name", schema: schema, quote: quoteIdentifier))
        AFTER INSERT ON \(quoteIdentifier(table))
        BEGIN
            -- INSERT INTO audit ...;
        END;
        """
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        "DROP TRIGGER IF EXISTS \(SQLiteMasterQueries.qualifiedTable(name, schema: schema, quote: quoteIdentifier))"
    }

    /// A view's `CREATE VIEW` sits in `sqlite_master` beside the tables, so one read answers both.
    /// The view goes back exactly as it was written: SQLite keeps a trailing comment in it, which a
    /// `;` appended here would land inside.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeStringLiteral(table)
        let query = """
            SELECT type, sql FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
            WHERE type IN ('table', 'view') AND name = '\(safeTable)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[safe: 1]?.asText else {
            throw LibSQLError(message: "Failed to fetch DDL for table '\(table)'")
        }

        guard firstRow[safe: 0]?.asText != "view" else { return ddl }
        let formatted = formatDDL(ddl)
        return formatted.hasSuffix(";") ? formatted : formatted + ";"
    }

    /// `sqlite_master` stores each index's own `CREATE INDEX` text, which is what `sqlite3 .dump`
    /// replays and which carries a partial predicate, an expression key, a collation and a sort
    /// direction exactly as written. An index SQLite created for itself to back a UNIQUE or PRIMARY
    /// KEY constraint has a null `sql`, so testing for that is what keeps `sqlite_autoindex_*` out
    /// of the dump: those come back with the constraint inside `CREATE TABLE`.
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let result = try await execute(query: """
            SELECT sql FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
            WHERE type = 'index'
              AND tbl_name = '\(escapeStringLiteral(table))'
              AND sql IS NOT NULL
            ORDER BY name
            """)
        return result.rows.compactMap { $0[safe: 0]?.asText }
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let safeView = escapeStringLiteral(view)
        let query = """
            SELECT sql FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
            WHERE type = 'view' AND name = '\(safeView)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0].asText else {
            throw LibSQLError(message: "Failed to fetch definition for view '\(view)'")
        }

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let qualified = SQLiteMasterQueries.qualifiedTable(table, schema: schema, quote: quoteIdentifier)
        let countQuery = "SELECT COUNT(*) FROM (SELECT 1 FROM \(qualified) LIMIT 100001)"
        let countResult = try await execute(query: countQuery)
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let countStr = row.first?.asText else { return nil }
            return Int64(countStr)
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
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"", options: .literal)
        return "\"\(escaped)\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "", options: .literal)
            .replacingOccurrences(of: "'", with: "''", options: .literal)
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

    // Remote runs every statement on a stream of its own, so a pragma is gone before the next statement runs.
    func foreignKeyDisableStatements() -> [String]? {
        isLocalMode ? ["PRAGMA foreign_keys = OFF"] : nil
    }

    func foreignKeyEnableStatements() -> [String]? {
        isLocalMode ? ["PRAGMA foreign_keys = ON"] : nil
    }

    // MARK: - Session Scope

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        guard isLocalMode else { return nil }
        return try await SQLiteSessionScope.open(for: purpose) { try await self.execute(query: $0) }
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        guard isLocalMode else { return }
        try await SQLiteSessionScope.close(scope) { try await self.execute(query: $0) }
    }

    // MARK: - Table Operations

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["DELETE FROM \(SQLiteMasterQueries.qualifiedTable(table, schema: schema, quote: quoteIdentifier))"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        "DROP \(objectType) IF EXISTS \(SQLiteMasterQueries.qualifiedTable(name, schema: schema, quote: quoteIdentifier))"
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            '\(escapeStringLiteral(SQLiteMasterQueries.attachedSchema(schema) ?? ""))' as schema,
            name,
            type as kind,
            '' as charset,
            '' as collation,
            '' as estimated_rows,
            '' as total_size,
            '' as data_size,
            '' as index_size,
            '' as comment
        FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
        WHERE type IN ('table', 'view')
        AND name NOT GLOB 'sqlite_*'
        AND name NOT GLOB 'libsql_*'
        ORDER BY name
        """
    }

    // MARK: - Transactions

    func beginTransaction() async throws {
        _ = try await executeTransactionStatement("BEGIN")
    }

    func commitTransaction() async throws {
        _ = try await executeTransactionStatement("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await executeTransactionStatement("ROLLBACK")
    }

    private func executeTransactionStatement(_ statement: String) async throws -> PluginQueryResult {
        guard case .local = getBackend() else {
            throw LibSQLError(message: String(localized: "Transactions are not supported in this mode"))
        }
        return try await execute(query: statement)
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
        "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(libSQLColumnDefinition(column))"
    }

    private func libSQLColumnDefinition(_ column: PluginColumnDefinition) -> String {
        var def = "\(quoteIdentifier(column.name)) \(column.dataType)"
        if !column.isNullable { def += " NOT NULL" }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            def += " DEFAULT \(defaultValue)"
        }
        return def
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    /// SQLite has no positional `ALTER`, so the order changes by rebuilding the table, using the
    /// shared recipe every SQLite-derived driver follows.
    ///
    /// Runnable only in local mode. A local database is a real SQLite handle that holds a
    /// transaction across statements, which is what makes the rebuild atomic; over HTTP each
    /// statement is its own request and the script has to be handed to the user instead.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        try Self.requireMainDatabase(schema)
        return try await SQLiteColumnReorderPlanner.plan(
            tableName: table,
            desiredOrder: desiredOrder,
            isRunnable: isLocalMode,
            execute: { try await self.execute(query: $0) }
        )
    }

    /// Foreign keys change the same way, and for the same reason: no SQLite `ALTER TABLE` can add
    /// or drop one, so the table is recreated with the keys the save asks for.
    func generateTableRebuildPlan(
        table: String,
        schema: String?,
        respecification: PluginTableRespecification
    ) async throws -> PluginColumnReorderPlan? {
        try Self.requireMainDatabase(schema)
        guard !respecification.isEmpty,
              let context = try await SQLiteTableRebuildPlanner.context(
                  tableName: table,
                  execute: { try await self.execute(query: $0) }
              ) else { return nil }

        return SQLiteTableRebuildPlanner.plan(
            tableName: table,
            context: context,
            respecification: respecification,
            renderColumn: { self.libSQLColumnDefinition($0) },
            isRunnable: isLocalMode
        )
    }

    /// The rebuild and reorder planners read the main database's catalog and write unqualified
    /// statements, so a table in an attached database is refused rather than rebuilt in the wrong file.
    static func requireMainDatabase(_ schema: String?) throws {
        guard SQLiteMasterQueries.attachedSchema(schema) == nil else {
            throw LibSQLError(
                message: String(localized: "The structure of a table in an attached database cannot be changed here.")
            )
        }
    }

    func columnReorderSchemaFingerprint(table: String, schema: String?) async throws -> String? {
        try Self.requireMainDatabase(schema)
        return try await SQLiteColumnReorderPlanner.schemaFingerprint(
            tableName: table,
            execute: { try await self.execute(query: $0) }
        )
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        SQLiteIndexCatalog.createStatement(for: index, table: table, quote: quoteIdentifier)
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX IF EXISTS \(quoteIdentifier(indexName))"
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        columnDefinition(column, inlinePK: column.isPrimaryKey)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        guard let tableName else {
            let unique = index.isUnique ? "UNIQUE " : ""
            let keys = SQLiteIndexCatalog.keyList(for: index, quote: quoteIdentifier)
            return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) \(keys)"
        }
        return SQLiteIndexCatalog.createStatement(for: index, table: tableName, quote: quoteIdentifier)
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
            def += " DEFAULT \(defaultValue)"
        }
        return def
    }

    private func foreignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let constraint = fk.name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(fk.name)) "
        var def = "\(constraint)FOREIGN KEY (\(cols)) REFERENCES \(quoteIdentifier(fk.referencedTable))"
        if !fk.referencedColumns.isEmpty {
            def += " (\(fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")))"
        }
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    private func getBackend() -> Backend? {
        lock.lock()
        defer { lock.unlock() }
        return backend
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }

    private func mapLocalResult(_ raw: LibSQLLocalRawResult) -> PluginQueryResult {
        PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated
        )
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
