//
//  SurrealDBPluginDriver.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

final class SurrealDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    let settings: SurrealDBConnectionConfig
    let client: SurrealRPCClient
    private let lock = NSLock()
    private var namespace: String
    private var database: String?
    private var kindCache: [String: [String: SurrealFieldKind]] = [:]

    init(config: DriverConnectionConfig) {
        let settings = SurrealDBConnectionConfig(config: config)
        self.settings = settings
        self.client = SurrealRPCClient(config: settings)
        self.namespace = settings.namespace
        self.database = settings.database.isEmpty ? nil : settings.database
    }

    var capabilities: PluginCapabilities {
        [.parameterizedQueries, .cancelQuery, .truncateTable, .multiSchema]
    }

    var serverVersion: String? {
        client.serverVersion
    }

    var supportsSchemas: Bool { true }

    var currentSchema: String? {
        lock.withLock { database }
    }

    var currentNamespace: String {
        lock.withLock { namespace }
    }

    var supportsTransactions: Bool { false }

    // MARK: - Lifecycle

    func connect() async throws {
        try settings.validate()
        client.start()
        do {
            try await client.probeVersion()
            try await client.authenticate()
            _ = try await client.query("RETURN 1;", namespace: currentScope().namespace, database: currentScope().database)
        } catch {
            client.stop()
            throw error
        }
    }

    func disconnect() {
        client.stop()
        lock.withLock { kindCache.removeAll() }
    }

    func ping() async throws {
        let scope = currentScope()
        _ = try await client.query("RETURN 1;", namespace: scope.namespace, database: scope.database)
    }

    func cancelQuery() throws {
        client.cancelInFlight()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        client.applyTimeout(seconds)
    }

    func beginTransaction() async throws {
        throw SurrealDBError.queryFailed(
            message: String(localized: "SurrealDB over HTTP does not support multi-request transactions."),
            kind: nil
        )
    }

    func commitTransaction() async throws {
        try await beginTransaction()
    }

    func rollbackTransaction() async throws {
        try await beginTransaction()
    }

    // MARK: - Scope

    func currentScope() -> SurrealScope {
        lock.withLock { SurrealScope(namespace: namespace, database: database) }
    }

    func scope(forSchema schema: String?) -> SurrealScope {
        lock.withLock {
            SurrealScope(namespace: namespace, database: schema ?? database)
        }
    }

    func switchDatabase(to database: String) async throws {
        lock.withLock {
            namespace = database
            self.database = nil
            kindCache.removeAll()
        }
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock {
            database = schema
            kindCache.removeAll()
        }
    }

    func cachedKinds(for table: String) -> [String: SurrealFieldKind] {
        lock.withLock { kindCache[table] ?? [:] }
    }

    func mergeKinds(_ kinds: [String: SurrealFieldKind], for table: String) {
        guard !kinds.isEmpty else { return }
        lock.withLock {
            kindCache[table, default: [:]].merge(kinds) { current, _ in current }
        }
    }

    func learnKinds(from value: SurrealValue) {
        let rows: [SurrealValue]
        switch value {
        case let .array(items):
            rows = items
        case .object:
            rows = [value]
        default:
            return
        }

        var learned: [String: [String: SurrealFieldKind]] = [:]
        for row in rows {
            guard let pairs = row.objectPairs,
                  case let .recordId(record)? = row[SurrealInfoParser.recordIdColumn] else { continue }
            for pair in pairs where !SurrealInfoParser.isReservedColumn(pair.key) {
                guard learned[record.table]?[pair.key] == nil,
                      let kind = SurrealFieldKind.infer(from: pair.value) else { continue }
                learned[record.table, default: [:]][pair.key] = kind
            }
        }
        for (table, kinds) in learned {
            mergeKinds(kinds, for: table)
        }
    }

    // MARK: - Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let scope = currentScope()
        let started = Date()
        let results = try await client.query(query, namespace: scope.namespace, database: scope.database)
        if let failure = SurrealRPCClient.firstFailure(results) {
            throw failure
        }
        results.forEach { learnKinds(from: $0.value) }
        return Self.result(from: results, elapsed: Date().timeIntervalSince(started))
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else { return try await execute(query: query) }

        let variables = parameters.enumerated().map { index, cell in
            (key: "p\(index)", value: SurrealCellCoder.value(from: cell))
        }
        let scope = currentScope()
        let started = Date()
        let results = try await client.query(
            query,
            variables: variables,
            namespace: scope.namespace,
            database: scope.database
        )
        if let failure = SurrealRPCClient.firstFailure(results) {
            throw failure
        }
        results.forEach { learnKinds(from: $0.value) }
        return Self.result(from: results, elapsed: Date().timeIntervalSince(started))
    }

    static func result(from results: [SurrealStatementResult], elapsed: TimeInterval) -> PluginQueryResult {
        guard let last = results.last else {
            return PluginQueryResult(
                columns: [],
                columnTypeNames: [],
                rows: [],
                rowsAffected: 0,
                executionTime: elapsed
            )
        }

        let flattened = SurrealRowFlattener.flatten(last.value)
        let affected = rowsAffected(last.value)
        return PluginQueryResult(
            columns: flattened.columns,
            columnTypeNames: flattened.columnTypeNames,
            rows: flattened.rows,
            rowsAffected: affected,
            executionTime: elapsed
        )
    }

    private static func rowsAffected(_ value: SurrealValue) -> Int {
        guard case let .array(items) = value else { return 0 }
        return items.count
    }

    // MARK: - Query building

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        SurrealQueryBuilder.browse(
            table: table,
            scope: scope(forSchema: schema),
            sortColumns: Self.sorts(sortColumns, columns: columns),
            limit: limit,
            offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        SurrealQueryBuilder.filtered(
            table: table,
            scope: scope(forSchema: schema),
            filters: filters,
            logicMode: logicMode,
            sortColumns: Self.sorts(sortColumns, columns: columns),
            limit: limit,
            offset: offset
        )
    }

    func fetchFilteredRowCount(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) async throws -> Int? {
        try await count(table: table, schema: nil, filters: filters, logicMode: logicMode)
    }

    func count(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) async throws -> Int? {
        let scope = scope(forSchema: schema)
        let query = SurrealQueryBuilder.count(table: table, scope: scope, filters: filters, logicMode: logicMode)
        let results = try await client.query(query, namespace: scope.namespace, database: scope.database)
        if let failure = SurrealRPCClient.firstFailure(results) {
            throw failure
        }
        guard let rows = results.last?.value.arrayValues, let total = rows.first?["total"]?.intValue else {
            return 0
        }
        return Int(total)
    }

    static func sorts(
        _ sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> [(column: String, ascending: Bool)] {
        sortColumns.compactMap { sort in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            return (column: columns[sort.columnIndex], ascending: sort.ascending)
        }
    }

    // MARK: - Mutations

    func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        SurrealStatementGenerator.statements(
            table: table,
            scope: scope(forSchema: schema),
            columns: columns,
            kinds: cachedKinds(for: table),
            changes: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    // MARK: - Dialect helpers

    func quoteIdentifier(_ name: String) -> String {
        SurrealQL.quoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        SurrealQL.escapeStringLiteral(value)
    }

    func castColumnToText(_ column: String) -> String {
        "<string> " + SurrealQL.quoteIdentifier(column)
    }

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN " + sql
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        [SurrealQueryBuilder.compose(
            scope: scope(forSchema: schema),
            statement: "DELETE " + SurrealQL.quoteIdentifier(table) + ";"
        )]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        let keyword: String
        switch objectType.uppercased() {
        case "NAMESPACE":
            keyword = "NAMESPACE"
        case "DATABASE":
            keyword = "DATABASE"
        default:
            keyword = "TABLE"
        }
        let statement = "REMOVE \(keyword) " + SurrealQL.quoteIdentifier(name) + ";"
        guard keyword == "TABLE" else { return statement }
        return SurrealQueryBuilder.compose(scope: scope(forSchema: schema), statement: statement)
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        SurrealQueryBuilder.compose(
            scope: scope(forSchema: schema),
            statement: "SELECT * FROM " + SurrealQL.quoteIdentifier(table) + ";"
        )
    }
}
