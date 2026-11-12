//
//  CloudflareD1PluginDriver.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

// MARK: - Error

nonisolated private struct CloudflareD1Error: Error, PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }

    static let notConnected = CloudflareD1Error(message: String(localized: "Not connected to database"))
}

// MARK: - Plugin Driver

nonisolated final class CloudflareD1PluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let sessionConfiguration: URLSessionConfiguration
    private var httpClient: D1HttpClient?
    private var _serverVersion: String?
    private var _resolvedDatabaseName: String?
    private var databaseNameToUuid: [String: String] = [:]
    private let lock = NSLock()

    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudflareD1PluginDriver")

    private static let lexicalGrammar: SQLLexicalGrammar =
        SQLLexicalProfile.curated(forDatabaseTypeId: CloudflareD1Plugin.databaseTypeId)?.grammar ?? .ansi

    var serverVersion: String? {
        lock.lock()
        defer { lock.unlock() }
        return _serverVersion
    }

    /// The name of the database the client points at, set at connect and by every switch, whether the connection
    /// named it or gave its UUID.
    ///
    /// PluginKit's `currentDatabase` stays nil on purpose. The Mac adopts that value at connect as the browse
    /// database, so a connection stored by UUID would re-key its per-database state (favorites, filters, tabs).
    var resolvedDatabaseName: String? {
        lock.withLock { _resolvedDatabaseName }
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var parameterStyle: ParameterStyle { .questionMark }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .alterTableDDL,
            .truncateTable,
            .cancelQuery,
            .schemaCompare,
            .dataCompare,
        ]
    }

    /// Every client the driver creates copies `sessionConfiguration`, so a test can route the driver's requests
    /// through its own `URLProtocol`.
    init(config: DriverConnectionConfig, sessionConfiguration: URLSessionConfiguration = .default) {
        self.config = config
        self.sessionConfiguration = sessionConfiguration
    }

    // MARK: - Connection

    func connect() async throws {
        guard let accountId = config.additionalFields[CloudflareD1Plugin.accountIdFieldId], !accountId.isEmpty else {
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
        let connectTimeout = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout().requestTimeoutInterval * 1_000)
        )
        let deadline = PluginConnectDeadline(milliseconds: connectTimeout)

        let client = D1HttpClient(accountId: accountId, apiToken: apiToken, databaseId: "")
        client.createSession(configuration: sessionConfiguration, connectDeadline: deadline)

        // The real failure goes to the user: an expired token, a rate limit or no network each needs its own fix.
        let details: D1DatabaseInfo
        do {
            guard let found = try await Self.lookUpDatabase(databaseName, client: client) else {
                throw CloudflareD1Error(
                    message: String(format: String(localized: "Database '%@' not found in account"), databaseName)
                )
            }
            details = found
        } catch {
            client.invalidateSession()
            Self.logger.error("Cloudflare D1 connect failed: \(Self.logSummary(of: error), privacy: .public)")
            throw error
        }

        client.databaseId = details.uuid
        client.finishConnecting()

        lock.withLock {
            _serverVersion = details.version ?? "D1"
            _resolvedDatabaseName = details.name
            databaseNameToUuid[details.name] = details.uuid
            httpClient = client
        }

        Self.logger.debug("Connected to Cloudflare D1 database: \(details.name)")
    }

    func disconnect() {
        lock.lock()
        httpClient?.invalidateSession()
        httpClient = nil
        _resolvedDatabaseName = nil
        lock.unlock()
    }

    /// The databases an account holds, for a form that offers them before any connection exists. It reads through
    /// the same paged client a connected driver uses.
    static func listDatabases(
        accountId: String,
        apiToken: String,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> [D1DatabaseInfo] {
        guard !accountId.isEmpty else {
            throw CloudflareD1Error(message: String(localized: "Account ID is required"))
        }
        guard !apiToken.isEmpty else {
            throw CloudflareD1Error(message: String(localized: "API Token is required"))
        }
        let client = D1HttpClient(accountId: accountId, apiToken: apiToken, databaseId: "")
        client.createSession(configuration: sessionConfiguration)
        defer { client.invalidateSession() }
        return try await client.listDatabases()
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

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let startTime = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let anyParams: [Any?] = try parameters.map { param -> Any? in
            switch param {
            case .null: return nil
            case .text(let s): return s
            // The API takes JSON parameters and documents no binary form, so bytes sent as text would be stored as
            // that text, not as the value.
            case .bytes:
                throw CloudflareD1Error(
                    message: String(localized: "Cloudflare D1 cannot bind a binary value through its API.")
                )
            }
        }
        let payload = try await client.executeRaw(sql: trimmed, params: anyParams)
        let executionTime = Date().timeIntervalSince(startTime)
        return mapRawResult(payload, executionTime: executionTime)
    }

    /// D1 fails a result over 50 MB from 2026-11-04 and answers each request with the whole result, so a read that
    /// names no limit is sent with one: one row past the cap, which tells a trimmed result from a complete one.
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        guard rowCap > 0, let statement = Self.boundableStatement(query) else { return nil }
        let sent = SQLStatementRowLimit.hasExplicitRowLimit(statement, countsTop: false, grammar: Self.lexicalGrammar)
            ? query
            : SQLStatementRowLimit.appendingLimit(rowCap + 1, to: statement)
        let result = try await execute(query: sent)
        guard result.rows.count > rowCap else { return result }
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: Array(result.rows.prefix(rowCap)),
            rowsAffected: result.rowsAffected,
            timing: result.timing,
            isTruncated: true,
            statusMessage: result.statusMessage,
            columnMeta: result.columnMeta
        )
    }

    /// The one statement of `query`, past its terminator and any comment after it, when a trailing `LIMIT` is valid
    /// on it: a SELECT, or a WITH list whose statement is a SELECT, with no compound term that is a bare VALUES list,
    /// which SQLite takes no LIMIT after. Nil for several statements: D1 runs them all and answers with the first
    /// one's rows, so a LIMIT appended to the last would bound the wrong one.
    private static func boundableStatement(_ query: String) -> String? {
        let grammar = lexicalGrammar
        let statements = SQLStatementScanner.allStatements(in: query, grammar: grammar)
        guard statements.count == 1, let statement = statements.first,
              let keyword = SQLStatementRowLimit.leadingKeyword(statement, grammar: grammar)
        else { return nil }
        switch keyword {
        case "SELECT":
            return SQLStatementRowLimit.hasCompoundValuesTerm(statement, grammar: grammar) ? nil : statement
        case "WITH":
            guard let reading = SQLCommonTableExpressions.read(statement, grammar: grammar) else { return nil }
            let main = (statement as NSString).substring(from: reading.mainStatement)
            guard SQLStatementRowLimit.leadingKeyword(main, grammar: grammar) == "SELECT",
                  !SQLStatementRowLimit.hasCompoundValuesTerm(main, grammar: grammar)
            else { return nil }
            return statement
        default:
            return nil
        }
    }

    func executeBatch(queries: [String]) async throws -> [PluginQueryResult] {
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let startTime = Date()
        let statements = queries.map { (sql: $0, params: nil as [Any?]?) }
        let payloads = try await client.executeBatchRaw(statements: statements)
        let elapsed = Date().timeIntervalSince(startTime)

        return payloads.map { payload in
            mapRawResult(payload, executionTime: payload.meta?.duration ?? (elapsed / Double(payloads.count)))
        }
    }

    func cancelQuery() throws {
        lock.lock()
        httpClient?.cancelAll()
        lock.unlock()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        let client = lock.withLock { httpClient }
        client?.setQueryTimeout(seconds)
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
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let payload = try await client.executeRaw(sql: query)

        let columns = payload.results.columns ?? []
        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columns.map { _ in "" },
            estimatedRowCount: nil
        )))

        let rawRows = payload.results.rows ?? []
        if !rawRows.isEmpty {
            let rows = rawRows.map { rawRow in
                rawRow.map(\.cellValue)
            }
            continuation.yield(.rows(rows))
        }

        continuation.finish()
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let query = """
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view')
            AND name NOT GLOB 'sqlite_*'
            AND name NOT GLOB '_cf_*'
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
        let query = "PRAGMA table_info('\(safeTable)')"
        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[1].asText,
                  let dataType = row[2].asText else {
                return nil
            }

            let isNullable = row[3].asText == "0"
            let isPrimaryKey = row[5].asText != nil && row[5].asText != "0"
            let defaultValue = cloudflareD1DefaultValueFromCatalog(row[4].asText)

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue
            )
        }
    }

    var fetchesAllColumnsInOneRequest: Bool { true }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let query = """
            SELECT m.name AS tbl, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk
            FROM sqlite_master m, pragma_table_info(m.name) p
            WHERE m.type = 'table' AND m.name NOT GLOB 'sqlite_*' AND m.name NOT GLOB '_cf_*'
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
            let defaultValue = cloudflareD1DefaultValueFromCatalog(row[5].asText)
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
        let query = SQLiteForeignKeyGrouping.schemaForeignKeysQuery(excludingTableGlob: "_cf_*")
        return SQLiteForeignKeyGrouping.foreignKeysByTable(fromRows: try await execute(query: query).rows)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let result = try await execute(query: SQLiteIndexCatalog.indexesQuery(table: table))
        return SQLiteIndexCatalog.indexes(fromRows: result.rows)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let result = try await execute(query: SQLiteForeignKeyGrouping.foreignKeysQuery(table: table))
        return SQLiteForeignKeyGrouping.foreignKeys(table: table, fromRows: result.rows)
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await sqliteTriggerList(table: table)
    }

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

    /// A view's `CREATE VIEW` sits in `sqlite_master` beside the tables, so one read answers both.
    /// The view goes back exactly as it was written: SQLite keeps a trailing comment in it, which a
    /// `;` appended here would land inside.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeStringLiteral(table)
        let query = """
            SELECT type, sql FROM sqlite_master
            WHERE type IN ('table', 'view') AND name = '\(safeTable)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[safe: 1]?.asText else {
            throw CloudflareD1Error(message: "Failed to fetch DDL for table '\(table)'")
        }

        guard firstRow[safe: 0]?.asText != "view" else { return ddl }
        return ddl.hasSuffix(";") ? ddl : ddl + ";"
    }

    /// `sqlite_master` stores each index's own `CREATE INDEX` text, which is what `sqlite3 .dump`
    /// replays and which carries a partial predicate, an expression key, a collation and a sort
    /// direction exactly as written. An index SQLite created for itself to back a UNIQUE or PRIMARY
    /// KEY constraint has a null `sql`, so testing for that is what keeps `sqlite_autoindex_*` out
    /// of the dump: those come back with the constraint inside `CREATE TABLE`.
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let result = try await execute(query: """
            SELECT sql FROM sqlite_master
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
            SELECT sql FROM sqlite_master
            WHERE type = 'view' AND name = '\(safeView)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0].asText else {
            throw CloudflareD1Error(message: "Failed to fetch definition for view '\(view)'")
        }

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let countQuery = "SELECT COUNT(*) FROM (SELECT 1 FROM \(quoteIdentifier(table)) LIMIT 100001)"
        let countResult = try await execute(query: countQuery)
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let countStr = row.first else { return nil }
            return Int64(countStr.asText ?? "0")
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

        lock.withLock {
            databaseNameToUuid.removeAll()
            for db in databases {
                databaseNameToUuid[db.name] = db.uuid
            }
        }

        return databases.map(\.name)
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(fields: [], footnote: nil)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let newDb = try await client.createDatabase(name: request.name)

        lock.withLock { databaseNameToUuid[newDb.name] = newDb.uuid }
    }

    func dropDatabase(name: String) async throws {
        guard let client = getClient() else {
            throw CloudflareD1Error.notConnected
        }

        let cached = lock.withLock { databaseNameToUuid[name] }
        let databaseId: String
        if let cached {
            databaseId = cached
        } else if Self.isUuid(name) {
            databaseId = name
        } else {
            guard let found = try await Self.lookUpDatabase(name, client: client) else {
                throw CloudflareD1Error(message: String(format: String(localized: "Database '%@' not found"), name))
            }
            databaseId = found.uuid
        }

        try await client.deleteDatabase(databaseId: databaseId)

        lock.withLock { databaseNameToUuid = databaseNameToUuid.filter { $0.value != databaseId } }
    }

    func switchDatabase(to database: String) async throws {
        let cached = lock.withLock { () -> (name: String, uuid: String)? in
            if let uuid = databaseNameToUuid[database] { return (name: database, uuid: uuid) }
            return databaseNameToUuid.first { $0.value == database }.map { (name: $0.key, uuid: $0.value) }
        }

        let target: (name: String, uuid: String)
        if let cached {
            target = cached
        } else {
            guard let client = getClient() else {
                throw CloudflareD1Error.notConnected
            }
            guard let found = try await Self.lookUpDatabase(database, client: client) else {
                throw CloudflareD1Error(
                    message: String(format: String(localized: "Database '%@' not found"), database)
                )
            }
            target = (found.name, found.uuid)
        }

        lock.withLock {
            guard let httpClient else { return }
            databaseNameToUuid[target.name] = target.uuid
            httpClient.databaseId = target.uuid
            _resolvedDatabaseName = target.name
        }
    }

    /// One GET answers a name or a UUID with both. Nil when the account holds no such database; every other failure
    /// is thrown as it came, so an expired token never reads as a missing database.
    private static func lookUpDatabase(_ nameOrId: String, client: D1HttpClient) async throws -> D1DatabaseInfo? {
        // The text goes into the URL path, so only the two shapes D1 accepts get that far.
        guard isUuid(nameOrId) || isDatabaseName(nameOrId) else {
            throw CloudflareD1Error(
                message: String(format: String(localized: "'%@' is not a Cloudflare D1 database name or UUID"), nameOrId)
            )
        }
        do {
            return try await client.getDatabaseDetails(nameOrId: nameOrId)
        } catch let error as D1HttpError where error.statusCode == 404 {
            return nil
        }
    }

    // The status and the error's type only: an error's text may carry a response body.
    private static func logSummary(of error: Error) -> String {
        if let error = error as? D1HttpError {
            return "D1HttpError status \(error.statusCode.map { String($0) } ?? "none")"
        }
        if let error = error as? URLError {
            return "URLError \(error.code.rawValue)"
        }
        return String(describing: type(of: error))
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
        AND name NOT GLOB 'sqlite_*'
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
        guard !definition.columns.isEmpty, definition.columns.allSatisfy({ Self.columnRefusal($0) == nil }) else { return nil }

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
        guard Self.columnRefusal(column) == nil else { return nil }
        var def = "\(quoteIdentifier(column.name)) \(column.dataType)"
        if !column.isNullable { def += " NOT NULL" }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            def += " DEFAULT \(defaultValue)"
        }
        return "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(def)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    /// SQLite has no positional `ALTER`, so the order changes by rebuilding the table, using the
    /// shared recipe every SQLite-derived driver follows.
    ///
    /// Never run by TablePro. D1 answers each statement over its own HTTP request, so nothing can
    /// hold the rebuild's transaction open across them, and a half-applied rebuild is data loss.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        try await SQLiteColumnReorderPlanner.plan(
            tableName: table,
            desiredOrder: desiredOrder,
            isRunnable: false,
            execute: { try await self.execute(query: $0) }
        )
    }

    // Handed to the user, never run: D1 cannot hold the rebuild's transaction across its per-statement requests.
    func generateTableRebuildPlan(
        table: String,
        schema: String?,
        respecification: PluginTableRespecification
    ) async throws -> PluginColumnReorderPlan? {
        if let refusal = Self.respecificationRefusal(respecification) { throw CloudflareD1Error(message: refusal) }
        guard !respecification.isEmpty,
              let context = try await SQLiteTableRebuildPlanner.context(
                  tableName: table,
                  execute: { try await self.execute(query: $0) }
              ) else { return nil }

        return SQLiteTableRebuildPlanner.plan(
            tableName: table,
            context: context,
            respecification: respecification,
            renderColumn: { self.d1ColumnDefinition($0, inlinePK: false) },
            isRunnable: false
        )
    }

    func columnReorderSchemaFingerprint(table: String, schema: String?) async throws -> String? {
        try await SQLiteColumnReorderPlanner.schemaFingerprint(
            tableName: table,
            execute: { try await self.execute(query: $0) }
        )
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        guard Self.indexRefusal(index) == nil else { return nil }
        return SQLiteIndexCatalog.createStatement(for: index, table: table, quote: quoteIdentifier)
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        switch operation {
        case .addColumn(let column):
            return Self.columnRefusal(column)
        case .addIndex(let index):
            return Self.indexRefusal(index)
        default:
            return nil
        }
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX IF EXISTS \(quoteIdentifier(indexName))"
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        guard Self.columnRefusal(column) == nil else { return nil }
        return d1ColumnDefinition(column, inlinePK: column.isPrimaryKey)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        guard Self.indexRefusal(index) == nil else { return nil }
        guard let tableName else {
            let unique = index.isUnique ? "UNIQUE " : ""
            let keys = SQLiteIndexCatalog.keyList(for: index, quote: quoteIdentifier)
            return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) \(keys)"
        }
        return SQLiteIndexCatalog.createStatement(for: index, table: tableName, quote: quoteIdentifier)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        d1ForeignKeyDefinition(fk)
    }

    // MARK: - Private Helpers

    // Type and default text, from the catalog or the user, goes into DDL only as one type or expression.
    private static func columnRefusal(name: String, type: String?, defaultValue: String?) -> String? {
        let typeId = CloudflareD1Plugin.databaseTypeId
        if let type, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !SQLExpressionFragment.isSingleType(type, databaseTypeId: typeId) {
            return String(format: String(localized: "The type of column %@ cannot be written as SQL."), name)
        }
        if let defaultValue, !defaultValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !SQLExpressionFragment.isSingleExpression(defaultValue, databaseTypeId: typeId) {
            return String(format: String(localized: "The default of column %@ cannot be written as SQL."), name)
        }
        return nil
    }

    private static func columnRefusal(_ column: PluginColumnDefinition) -> String? {
        columnRefusal(name: column.name, type: column.dataType, defaultValue: column.defaultValue)
    }

    private static func respecificationRefusal(_ respecification: PluginTableRespecification) -> String? {
        respecification.addedColumns.lazy.compactMap { columnRefusal($0) }.first
            ?? respecification.alteredColumns.lazy.compactMap {
                columnRefusal(name: $0.column, type: $0.type, defaultValue: $0.defaultValue)
            }.first
    }

    private static func indexRefusal(_ index: PluginIndexDefinition) -> String? {
        let typeId = CloudflareD1Plugin.databaseTypeId
        let keys = index.ddlMethodAndKeys?.nilIfEmpty.map { [$0] } ?? (index.expressions ?? [])
        guard keys.allSatisfy({ SQLExpressionFragment.isSingleExpression($0, databaseTypeId: typeId) }) else {
            return String(format: String(localized: "Index %@ has a key part that is not one SQL expression."), index.name)
        }
        if let predicate = index.whereClause?.nilIfEmpty, !SQLExpressionFragment.isSingleExpression(predicate, databaseTypeId: typeId) {
            return String(format: String(localized: "The condition of index %@ cannot be written as SQL."), index.name)
        }
        return nil
    }

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
            def += " DEFAULT \(defaultValue)"
        }
        return def
    }

    private func d1ForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
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

    private func getClient() -> D1HttpClient? {
        lock.lock()
        defer { lock.unlock() }
        return httpClient
    }

    // Checked scalar by scalar: a regex `$` also matches before a trailing newline, which would reach the URL path.
    private static func isUuid(_ string: String) -> Bool {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count == 36 else { return false }
        return scalars.enumerated().allSatisfy { index, scalar in
            [8, 13, 18, 23].contains(index) ? scalar == "-" : scalar.properties.isASCIIHexDigit
        }
    }

    // D1's name rule, `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`, from Cloudflare's API schema.
    private static func isDatabaseName(_ string: String) -> Bool {
        guard let first = string.unicodeScalars.first, isASCIIAlphanumeric(first) else { return false }
        return string.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    private func mapRawResult(_ payload: D1RawResultPayload, executionTime: TimeInterval) -> PluginQueryResult {
        let columns = payload.results.columns ?? []
        let rawRows = payload.results.rows ?? []

        var rows: [[PluginCellValue]] = []
        var truncated = false

        for rawRow in rawRows {
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }
            rows.append(rawRow.map(\.cellValue))
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
}
