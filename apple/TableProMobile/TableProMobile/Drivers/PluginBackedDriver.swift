import Foundation
import os
import TableProDatabase
import TableProLogRedaction
import TableProModels
import TableProPluginKit

// Runs a driver the Mac ships as a plugin, compiled into this app, the way the Mac's PluginDriverAdapter does. Its
// rows are written with SQLBuilder's statements, as the Mac writes them for a plugin that generates none of its own.
nonisolated class PluginBackedDriver: DatabaseDriver, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginBackedDriver")

    let plugin: any PluginDatabaseDriver
    let dialedHosts: [String]
    private let queryTimeoutSeconds: Int?
    private let readsOnly: @Sendable (String) -> Bool
    private let provesReads: Bool
    private let cancelsRunningRequest: (@Sendable () -> Void)?
    private let requestGate = SerialRequestGate()
    private let sessionDatabase = OSAllocatedUnfairLock<String?>(initialState: nil)

    // `provesReads`: `readsOnly` is a proof rather than a guess, so a statement it passes runs marked read-only and the
    // plugin refuses any write it makes, as the Mac's PluginStatementContext.statement does for MongoDB.
    // `cancelsRunningRequest`: the plugin's own cancel, which stops whatever it is running, so its requests run one at
    // a time and a cancelled one stops only itself.
    init(
        plugin: any PluginDatabaseDriver,
        dialedHosts: [String],
        queryTimeoutSeconds: Int? = nil,
        readsOnly: @escaping @Sendable (String) -> Bool,
        provesReads: Bool = false,
        cancelsRunningRequest: (@Sendable () -> Void)? = nil
    ) {
        self.plugin = plugin
        self.dialedHosts = dialedHosts
        self.queryTimeoutSeconds = queryTimeoutSeconds
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
            Self.logger.warning("The query timeout was not applied: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
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
        let locators = result.rowLocators.flatMap { $0.count == result.rows.count ? $0 : nil } ?? []

        var emitted = 0
        for (rowIndex, row) in result.rows.enumerated() {
            if Task.isCancelled {
                continuation.yield(.truncated(reason: .cancelled))
                return
            }
            if emitted >= options.maxRows {
                continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                return
            }
            let locator = locators.indices.contains(rowIndex) ? locators[rowIndex] : nil
            let cells = row.enumerated().map { index, value -> Cell in
                let ref = cellRef(
                    column: index < result.columns.count ? result.columns[index] : "",
                    row: row,
                    locator: locator,
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
                    return Cell.from(text: text, options: options, ref: ref)
                }
            }
            continuation.yield(.row(Row(cells: cells, locator: locator)))
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
        locator: String?,
        keyIndices: [Int?]?,
        options: StreamOptions
    ) -> CellRef? {
        guard let context = options.lazyContext, let keyIndices, !keyIndices.isEmpty else { return nil }
        var components: [PrimaryKeyComponent] = []
        for (key, index) in zip(context.primaryKeyColumns, keyIndices) {
            guard let index, index < row.count, case .text(let value) = row[index] else { return nil }
            components.append(PrimaryKeyComponent(column: key, value: value))
        }
        return CellRef(table: context.table, column: column, primaryKey: components, locator: locator)
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
}
