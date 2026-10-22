import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit

// Runs a driver the Mac ships as a plugin, compiled into this app, the way the Mac's PluginDriverAdapter does.
nonisolated class PluginBackedDriver: DriverRowWriting, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginBackedDriver")

    private let plugin: any PluginDatabaseDriver
    private let dialedHosts: [String]
    private let queryTimeoutSeconds: Int?
    private let readsOnly: @Sendable (String) -> Bool
    private let provesReads: Bool
    private let cancelsRunningRequest: (@Sendable () -> Void)?
    private let requestGate = SerialRequestGate()
    private let sessionDatabase = OSAllocatedUnfairLock<String?>(initialState: nil)
    let rowIdentity: RowIdentity

    // `provesReads`: `readsOnly` is a proof rather than a guess, so a statement it passes runs marked read-only and the
    // plugin refuses any write it makes, as the Mac's PluginStatementContext.statement does for MongoDB.
    // `cancelsRunningRequest`: the plugin's own cancel, which stops whatever it is running, so its requests run one at
    // a time and a cancelled one stops only itself.
    init(
        plugin: any PluginDatabaseDriver,
        dialedHosts: [String],
        queryTimeoutSeconds: Int? = nil,
        rowIdentity: RowIdentity,
        readsOnly: @escaping @Sendable (String) -> Bool,
        provesReads: Bool = false,
        cancelsRunningRequest: (@Sendable () -> Void)? = nil
    ) {
        self.plugin = plugin
        self.dialedHosts = dialedHosts
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.rowIdentity = rowIdentity
        self.readsOnly = readsOnly
        self.provesReads = provesReads
        self.cancelsRunningRequest = cancelsRunningRequest
    }

    // A cancel that lands before the plugin has started the request is cleared when it starts, so it is sent again
    // until the request has returned.
    func exclusively<T: Sendable>(_ request: () async throws -> T) async throws -> T {
        guard let cancel = cancelsRunningRequest else { return try await request() }
        try await requestGate.acquire()
        defer { requestGate.release() }
        let finished = OSAllocatedUnfairLock(initialState: false)
        defer { finished.withLock { $0 = true } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await request()
        } onCancel: {
            // Under the lock, so no cancel lands once the gate has passed to the next request.
            let cancelUnlessFinished: @Sendable () -> Bool = {
                finished.withLock { done in
                    if !done { cancel() }
                    return done
                }
            }
            guard !cancelUnlessFinished() else { return }
            Task.detached {
                repeat {
                    try? await Task.sleep(for: .milliseconds(100))
                } while !cancelUnlessFinished()
            }
        }
    }

    // The database the plugin is on once every request queued before this one has returned.
    func settledCurrentDatabase() async throws -> String? {
        try await exclusively { currentDatabase }
    }

    // The database the picker names, which the app's own requests run in.
    var pinnedDatabase: String? {
        sessionDatabase.withLock { $0 }
    }

    // A request the app makes for the database the picker names. A script's `use` can move the shell between its
    // statements, so the request runs back there and leaves the shell where the script put it.
    func inSessionDatabase<T: Sendable>(_ request: () async throws -> T) async throws -> T {
        let plugin = plugin
        return try await exclusively {
            guard let pinned = sessionDatabase.withLock({ $0 }), let moved = currentDatabase, moved != pinned else {
                return try await request()
            }
            try await plugin.switchDatabase(to: pinned)
            let result: Result<T, Error>
            do {
                result = .success(try await request())
            } catch {
                result = .failure(error)
            }
            try? await plugin.switchDatabase(to: moved)
            return try result.get()
        }
    }

    func statementContext(_ query: String) -> PluginStatementContext {
        var context = PluginStatementContext()
        context.readOnly = provesReads && readsOnly(query)
        return context
    }

    // MARK: - Connection

    func connect() async throws {
        for host in dialedHosts {
            try await LocalNetworkPermission.shared.ensureAccess(for: host)
        }
        try await plugin.connect()
        let opened = currentDatabase
        sessionDatabase.withLock { $0 = opened }
        guard let queryTimeoutSeconds else { return }
        // A server that refuses the limit still runs queries, as on the Mac.
        do {
            try await plugin.applyQueryTimeout(queryTimeoutSeconds)
        } catch {
            Self.logger.warning("The query timeout was not applied: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() async throws {
        plugin.disconnect()
    }

    func ping() async throws -> Bool {
        try await plugin.ping()
        return true
    }

    var serverVersion: String? { plugin.serverVersion }

    var currentDatabase: String? { nil }

    func escapeStringLiteral(_ value: String) -> String {
        plugin.escapeStringLiteral(value)
    }

    // MARK: - Queries

    func execute(query: String) async throws -> QueryResult {
        let context = statementContext(query)
        return QueryResult(from: try await exclusively { try await plugin.execute(query: query, context: context) })
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        stream(query: query, options: options, bindsToSession: false)
    }

    func stream(query: String, options: StreamOptions, bindsToSession: Bool) -> AsyncThrowingStream<StreamElement, Error> {
        let plugin = plugin
        let isRead = readsOnly(query)
        let context = statementContext(query)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request: () async throws -> PluginQueryResult = {
                        // Only a read may be bounded at its source: bounding abandons the rest of the statement.
                        if isRead, let bounded = try await plugin.executeBoundedQuery(query: query, rowCap: options.maxRows) {
                            return bounded
                        }
                        return try await plugin.executeUserQuery(
                            query: query, rowCap: options.maxRows, parameters: nil, context: context
                        )
                    }
                    let result = bindsToSession
                        ? try await self.inSessionDatabase(request)
                        : try await self.exclusively(request)
                    Self.emit(result, options: options, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // The plugin cancels whichever request it sent last, which can be another window's on this shared session. Stop
    // ends the run's stream instead, and the plugin stops and kills that request alone.
    func cancelCurrentQuery() async throws {}

    static func emit(
        _ result: PluginQueryResult,
        options: StreamOptions,
        into continuation: AsyncThrowingStream<StreamElement, Error>.Continuation
    ) {
        let columns = zip(result.columns, result.columnTypeNames).enumerated().map { index, pair in
            ColumnInfo(name: pair.0, typeName: pair.1, ordinalPosition: index)
        }
        continuation.yield(.columns(columns))
        let keyIndices = options.lazyContext.map { context in
            context.primaryKeyColumns.map { key in result.columns.firstIndex(of: key) }
        }

        var emitted = 0
        for row in result.rows {
            if Task.isCancelled {
                continuation.yield(.truncated(reason: .cancelled))
                return
            }
            if emitted >= options.maxRows {
                continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                return
            }
            let cells = row.enumerated().map { index, value -> Cell in
                let ref = cellRef(
                    column: index < result.columns.count ? result.columns[index] : "",
                    row: row,
                    keyIndices: keyIndices,
                    options: options
                )
                switch value {
                case .null:
                    return .null
                // Bytes stay binary: shown as hex text they would read as an editable value and match no row.
                case .bytes(let data):
                    return .binary(byteCount: data.count, ref: ref)
                case .text(let text):
                    let typeName = index < columns.count ? columns[index].typeName : nil
                    return Cell.from(legacyValue: text, columnTypeName: typeName, options: options, ref: ref)
                }
            }
            continuation.yield(.row(Row(cells: cells)))
            emitted += 1
        }

        if let message = result.statusMessage {
            continuation.yield(.statusMessage(message))
        }
        if result.rowsAffected != 0 {
            continuation.yield(.rowsAffected(result.rowsAffected))
        }
        // A plugin that capped the read itself returns exactly the cap and says it stopped there.
        if result.isTruncated {
            let reason: TruncationReason = emitted >= options.maxRows
                ? .rowCap(options.maxRows)
                : .driverLimit("driver returned isTruncated=true")
            continuation.yield(.truncated(reason: reason))
        }
    }

    private static func cellRef(
        column: String,
        row: [PluginCellValue],
        keyIndices: [Int?]?,
        options: StreamOptions
    ) -> CellRef? {
        guard let context = options.lazyContext, let keyIndices, !keyIndices.isEmpty else { return nil }
        var components: [PrimaryKeyComponent] = []
        for (key, index) in zip(context.primaryKeyColumns, keyIndices) {
            guard let index, index < row.count, case .text(let value) = row[index] else { return nil }
            components.append(PrimaryKeyComponent(column: key, value: value))
        }
        return CellRef(table: context.table, column: column, primaryKey: components)
    }

    // MARK: - Catalog

    // A catalog read shares the connection a cancel reaches, so it takes its turn with statements: a Stop for a
    // statement queued behind it would otherwise end the read.
    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let plugin = plugin
        return try await inSessionDatabase { try await plugin.fetchTables(schema: schema) }.map(TableInfo.init(from:))
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let plugin = plugin
        return try await inSessionDatabase { try await plugin.fetchColumns(table: table, schema: schema) }
            .enumerated().map { index, column in ColumnInfo(from: column, ordinalPosition: index) }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let plugin = plugin
        return try await inSessionDatabase { try await plugin.fetchIndexes(table: table, schema: schema) }
            .map(IndexInfo.init(from:))
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let plugin = plugin
        return try await inSessionDatabase { try await plugin.fetchForeignKeys(table: table, schema: schema) }
            .map(ForeignKeyInfo.init(from:))
    }

    func fetchDatabases() async throws -> [String] {
        let plugin = plugin
        return try await exclusively { try await plugin.fetchDatabases() }
    }

    // A MongoDB switch rebinds the shell, which waits for a running script, so it takes its turn too.
    func switchDatabase(to name: String) async throws {
        let plugin = plugin
        try await exclusively {
            try await plugin.switchDatabase(to: name)
            sessionDatabase.withLock { $0 = name }
        }
    }

    var supportsSchemas: Bool { plugin.supportsSchemas }

    func fetchSchemas() async throws -> [String] {
        let plugin = plugin
        return try await exclusively { try await plugin.fetchSchemas() }
    }

    func switchSchema(to name: String) async throws {
        let plugin = plugin
        try await exclusively { try await plugin.switchSchema(to: name) }
    }

    var currentSchema: String? { plugin.currentSchema }

    // MARK: - Transactions

    var supportsTransactions: Bool { plugin.supportsTransactions }

    func beginTransaction() async throws {
        try await plugin.beginTransaction()
    }

    func commitTransaction() async throws {
        try await plugin.commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await plugin.rollbackTransaction()
    }

    func sessionTransactionState() async -> DriverTransactionState {
        // Every statement commits on its own when the engine has no transactions, so nothing is ever pending.
        guard plugin.supportsTransactions else { return .idle }
        switch await plugin.sessionTransactionState() {
        case .idle: return .idle
        case .inTransaction, .abortedTransaction: return .explicitTransaction
        case .holdsSessionLocks: return .implicitTransaction
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: - Row writes

    func updateWrites(
        table: String,
        schema: String?,
        columns: [String],
        originalRow: [String?],
        changes: [(column: String, value: String?)]
    ) throws -> [PluginRowWrite] {
        let original = originalRow.map(PluginCellValue.init(optionalText:))
        let cellChanges = changes.compactMap { change -> (Int, String, PluginCellValue, PluginCellValue)? in
            guard let index = columns.firstIndex(of: change.column) else { return nil }
            let old = index < original.count ? original[index] : .null
            return (index, change.column, old, PluginCellValue(optionalText: change.value))
        }
        let rowChange = PluginRowChange(rowIndex: 0, type: .update, cellChanges: cellChanges, originalRow: original)
        return try generate(table: table, schema: schema, columns: columns, changes: [rowChange])
    }

    func deleteWrites(table: String, schema: String?, columns: [String], originalRow: [String?]) throws -> [PluginRowWrite] {
        let original = originalRow.map(PluginCellValue.init(optionalText:))
        let rowChange = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: original)
        return try generate(table: table, schema: schema, columns: columns, changes: [rowChange], deleted: [0])
    }

    func insertWrites(
        table: String,
        schema: String?,
        columns: [String],
        values: [(column: String, value: String?)]
    ) throws -> [PluginRowWrite] {
        // The plugin reads this text as "leave the column out", so storing it as a value cannot be expressed.
        if values.contains(where: { $0.value == Self.defaultSentinel }) {
            throw DatabaseError(message: String(format: String(
                localized: "The text %@ cannot be inserted: this database reads it as the column's default."
            ), Self.defaultSentinel))
        }
        let given = Dictionary(values.map { ($0.column, $0.value) }, uniquingKeysWith: { _, last in last })
        let row = columns.map { column -> PluginCellValue in
            guard let value = given[column] else { return .text(Self.defaultSentinel) }
            return PluginCellValue(optionalText: value)
        }
        let rowChange = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        return try generate(
            table: table, schema: schema, columns: columns, changes: [rowChange], inserted: [0: row]
        )
    }

    // A write with a lookup runs only on the rows the lookup finds, the way the Mac's DataWriteExecutor runs it.
    func run(_ writes: [PluginRowWrite]) async throws -> Int {
        let plugin = plugin
        return try await inSessionDatabase {
            var affected = 0
            for write in writes {
                var parameters = write.parameters
                if let lookup = write.lookup {
                    let found = try await Self.rows(lookup.query, lookup.parameters, on: plugin)
                    guard found.count == lookup.rowCount else {
                        throw found.count < lookup.rowCount ? RowChangeRefusal.rowNotFound : RowChangeRefusal.identicalRows
                    }
                    if lookup.pinsRows {
                        parameters += found.flatMap { $0 }
                    }
                }
                let result = parameters.isEmpty
                    ? try await plugin.execute(query: write.statement)
                    : try await plugin.executeParameterized(query: write.statement, parameters: parameters)
                affected += max(result.rowsAffected, 0)
                if let lookup = write.lookup, let check = lookup.check,
                   try await !Self.rows(check, lookup.checkParameters, on: plugin).isEmpty {
                    throw RowChangeRefusal.notApplied
                }
            }
            return affected
        }
    }

    private static func rows(
        _ query: String,
        _ parameters: [PluginCellValue],
        on plugin: any PluginDatabaseDriver
    ) async throws -> [[PluginCellValue]] {
        parameters.isEmpty
            ? try await plugin.execute(query: query).rows
            : try await plugin.executeParameterized(query: query, parameters: parameters).rows
    }

    // Unqualified and with the same predicates as the plugin's own row writes, so it finds the rows they would touch:
    // at most two.
    func matchingRowCount(table: String, schema: String?, columns: [String], row: [String?]) async throws -> Int {
        guard !columns.isEmpty, columns.count == row.count else { throw Self.cannotWrite }
        var parameters: [PluginCellValue] = []
        let conditions = zip(columns, row).map { column, value -> String in
            let quoted = plugin.quoteIdentifier(column)
            guard let value else { return "\(quoted) IS NULL" }
            parameters.append(.text(value))
            return "\(quoted) = ?"
        }
        let query = "SELECT 1 FROM \(plugin.quoteIdentifier(table)) WHERE \(conditions.joined(separator: " AND ")) LIMIT 2"
        let plugin = plugin
        return try await inSessionDatabase {
            try await plugin.executeParameterized(query: query, parameters: parameters).rows.count
        }
    }

    private static var cannotWrite: DatabaseError {
        DatabaseError(message: String(localized: "This database cannot write this change from iPhone or iPad."))
    }

    // The Mac's grid marks a cell left at the column default with this text, and the drivers leave such a column out.
    static let defaultSentinel = "__DEFAULT__"

    private func generate(
        table: String,
        schema: String?,
        columns: [String],
        changes: [PluginRowChange],
        inserted: [Int: [PluginCellValue]] = [:],
        deleted: Set<Int> = []
    ) throws -> [PluginRowWrite] {
        guard let writes = try pluginRowWrites(
            table: table, schema: schema, columns: columns, changes: changes, inserted: inserted, deleted: deleted
        ) else {
            throw Self.cannotWrite
        }
        return writes
    }

    func pluginRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        changes: [PluginRowChange],
        inserted: [Int: [PluginCellValue]],
        deleted: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try plugin.generateRowWrites(
            table: table,
            schema: schema,
            columns: columns,
            primaryKeyColumns: [],
            changes: changes,
            insertedRowData: inserted,
            deletedRowIndices: deleted,
            insertedRowIndices: Set(inserted.keys),
            context: PluginRowWriteContext()
        )
    }
}

nonisolated private extension PluginCellValue {
    init(optionalText value: String?) {
        self = value.map { .text($0) } ?? .null
    }
}
