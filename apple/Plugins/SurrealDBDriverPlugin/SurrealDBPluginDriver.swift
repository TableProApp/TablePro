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
    private let connectTimeoutMilliseconds: Int
    private var namespace: String
    private var database: String?
    private var kindCache: [String: [String: SurrealFieldKind]] = [:]
    private var heldKindCache: [String: [String: Set<SurrealFieldKind.Base>]] = [:]
    // What `DEFINE FIELD` says, kept apart from the kinds the first rows read happened to hold.
    private var declaredKindCache: [String: [String: SurrealFieldKind]] = [:]
    // Table, then record literal, then field: the kind each record's field held when last read.
    // Bounded by field entries, and evicted a table at a time, least recently read first.
    private var recordKindCache: [String: [String: [String: SurrealFieldKind.Base]]] = [:]
    private var recordKindEntries: [String: Int] = [:]
    private var recordKindTables: [String] = []
    private static let recordKindEntryLimit = 200_000
    private static let recordKindRowLimit = 20_000

    init(config: DriverConnectionConfig) {
        let settings = SurrealDBConnectionConfig(config: config)
        self.settings = settings
        self.client = SurrealRPCClient(config: settings)
        self.connectTimeoutMilliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: 60_000
        )
        self.namespace = settings.namespace
        self.database = settings.database.isEmpty ? nil : settings.database
    }

    var capabilities: PluginCapabilities {
        [.parameterizedQueries, .cancelQuery, .truncateTable, .multiSchema, .columnDefaultMarks]
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
        client.start(connectTimeoutMilliseconds: connectTimeoutMilliseconds)
        defer { client.finishConnecting() }
        do {
            try await client.probeVersion()
            try await client.authenticate()
            _ = try await client.query("RETURN 1;", namespace: currentScope().namespace, database: currentScope().database)
        } catch {
            client.stop()
            throw error
        }
    }

    // The record kinds outlive a reconnect: they describe rows of the same database that a grid still shows.
    func disconnect() {
        client.stop()
        lock.withLock {
            kindCache.removeAll()
            heldKindCache.removeAll()
            declaredKindCache.removeAll()
        }
    }

    private func clearKindCaches() {
        kindCache.removeAll()
        heldKindCache.removeAll()
        declaredKindCache.removeAll()
        recordKindCache.removeAll()
        recordKindEntries.removeAll()
        recordKindTables.removeAll()
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
            clearKindCaches()
        }
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock {
            database = schema
            clearKindCaches()
        }
    }

    func cachedHeldKinds(for table: String) -> [String: Set<SurrealFieldKind.Base>] {
        lock.withLock { heldKindCache[table] ?? [:] }
    }

    func cachedRecordKinds(for table: String) -> [String: [String: SurrealFieldKind.Base]] {
        lock.withLock { recordKindCache[table] ?? [:] }
    }

    func cachedKinds(for table: String) -> [String: SurrealFieldKind] {
        lock.withLock { kindCache[table] ?? [:] }
    }

    func cachedDeclaredKinds(for table: String) -> [String: SurrealFieldKind] {
        lock.withLock { declaredKindCache[table] ?? [:] }
    }

    func rememberDeclaredKinds(_ kinds: [String: SurrealFieldKind], for table: String) {
        lock.withLock { declaredKindCache[table] = kinds }
    }

    func mergeKinds(_ kinds: [String: SurrealFieldKind], for table: String) {
        guard !kinds.isEmpty else { return }
        lock.withLock {
            kindCache[table, default: [:]].merge(kinds) { current, _ in current }
        }
    }

    // `remembersRecords` is false for a whole-table read, an export or a stream, which no grid edits.
    func learnKinds(from value: SurrealValue, remembersRecords: Bool = true) {
        let rows: [SurrealValue]
        switch value {
        case let .array(items):
            rows = items
        case .object:
            rows = [value]
        default:
            return
        }

        let keepsRecords = remembersRecords && rows.count <= Self.recordKindRowLimit
        var learned: [String: [String: SurrealFieldKind]] = [:]
        var held: [String: [String: Set<SurrealFieldKind.Base>]] = [:]
        var byRecord: [String: [String: RecordFieldKinds]] = [:]
        for row in rows {
            guard let pairs = row.objectPairs,
                  case let .recordId(record)? = row[SurrealInfoParser.recordIdColumn] else { continue }
            var fields = RecordFieldKinds()
            for pair in pairs where !SurrealInfoParser.isReservedColumn(pair.key) {
                guard let kind = SurrealFieldKind.infer(from: pair.value) else {
                    if keepsRecords { fields.empty.insert(pair.key) }
                    continue
                }
                if keepsRecords {
                    if kind.base == .any { fields.empty.insert(pair.key) } else { fields.held[pair.key] = kind.base }
                }
                held[record.table, default: [:]][pair.key, default: []].insert(kind.base)
                guard learned[record.table]?[pair.key] == nil else { continue }
                learned[record.table, default: [:]][pair.key] = kind
            }
            if keepsRecords { byRecord[record.table, default: [:]][record.literal] = fields }
        }
        for (table, kinds) in learned {
            mergeKinds(kinds, for: table)
        }
        guard !held.isEmpty || !byRecord.isEmpty else { return }
        lock.withLock {
            for (table, fields) in held {
                for (field, bases) in fields {
                    heldKindCache[table, default: [:]][field, default: []].formUnion(bases)
                }
            }
            rememberRecordKinds(byRecord)
        }
    }

    private struct RecordFieldKinds {
        var held: [String: SurrealFieldKind.Base] = [:]
        var empty: Set<String> = []
    }

    // A projection names some fields, so each read updates the ones it names and keeps the rest.
    // Called under `lock`.
    private func rememberRecordKinds(_ reads: [String: [String: RecordFieldKinds]]) {
        let incoming = reads.values.reduce(0) { total, records in total + records.values.reduce(0) { $0 + $1.held.count } }
        guard incoming <= Self.recordKindEntryLimit else { return }
        for (table, records) in reads {
            mergeRecordKinds(records, into: table)
        }
        var total = recordKindEntries.values.reduce(0, +)
        while total > Self.recordKindEntryLimit, let oldest = recordKindTables.first(where: { reads[$0] == nil }) {
            total -= recordKindEntries[oldest] ?? 0
            forgetRecordKinds(of: oldest)
        }
        guard total > Self.recordKindEntryLimit else { return }
        // The tables just read outgrew the limit on their own over many pages: only this read's rows stay.
        for (table, records) in reads {
            forgetRecordKinds(of: table)
            mergeRecordKinds(records, into: table)
        }
    }

    private func mergeRecordKinds(_ records: [String: RecordFieldKinds], into table: String) {
        var cached = recordKindCache[table] ?? [:]
        var entries = recordKindEntries[table] ?? 0
        for (record, fields) in records {
            var known = cached[record] ?? [:]
            entries -= known.count
            known.merge(fields.held) { _, read in read }
            for field in fields.empty { known.removeValue(forKey: field) }
            entries += known.count
            cached[record] = known.isEmpty ? nil : known
        }
        recordKindCache[table] = cached
        recordKindEntries[table] = entries
        recordKindTables.removeAll { $0 == table }
        recordKindTables.append(table)
    }

    private func forgetRecordKinds(of table: String) {
        recordKindCache.removeValue(forKey: table)
        recordKindEntries.removeValue(forKey: table)
        recordKindTables.removeAll { $0 == table }
    }

    // MARK: - Execution

    func execute(query: String) async throws -> PluginQueryResult {
        try await execute(query: query, length: .display)
    }

    private func execute(query: String, length: SurrealTextLength) async throws -> PluginQueryResult {
        let scope = currentScope()
        let started = Date()
        let results = try await client.query(query, namespace: scope.namespace, database: scope.database)
        if let failure = SurrealRPCClient.firstFailure(results) {
            throw failure
        }
        results.forEach { learnKinds(from: $0.value, remembersRecords: length == .display) }
        return Self.result(from: results, elapsed: Date().timeIntervalSince(started), length: length)
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let result = try await self.execute(query: query, length: .whole)
                    continuation.yield(.header(PluginStreamHeader(
                        columns: result.columns,
                        columnTypeNames: result.columnTypeNames
                    )))
                    if !result.rows.isEmpty { continuation.yield(.rows(result.rows)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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
        return Self.result(from: results, elapsed: Date().timeIntervalSince(started), length: .display)
    }

    static func result(
        from results: [SurrealStatementResult],
        elapsed: TimeInterval,
        length: SurrealTextLength
    ) -> PluginQueryResult {
        guard let last = results.last else {
            return PluginQueryResult(
                columns: [],
                columnTypeNames: [],
                rows: [],
                rowsAffected: 0,
                executionTime: elapsed
            )
        }

        let flattened = SurrealRowFlattener.flatten(last.value, length: length)
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
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        SurrealQueryBuilder.filtered(
            table: table,
            scope: scope(forSchema: schema),
            filters: queryFilters,
            logicMode: logicMode,
            sortColumns: Self.sorts(sortColumns, columns: columns),
            limit: limit,
            offset: offset,
            columnKinds: columnKinds
        )
    }

    func fetchFilteredRowCount(
        table: String,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        try await count(table: table, schema: nil, filters: queryFilters, logicMode: logicMode)
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        try await count(table: table, schema: schema, filters: queryFilters, logicMode: logicMode)
    }

    func count(
        table: String,
        schema: String?,
        filters: [PluginQueryFilter],
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

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try SurrealStatementGenerator.rowWrites(
            table: table,
            scope: scope(forSchema: schema),
            columns: columns,
            kinds: cachedKinds(for: table),
            heldKinds: cachedHeldKinds(for: table),
            recordKinds: cachedRecordKinds(for: table),
            declaredKinds: cachedDeclaredKinds(for: table),
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
