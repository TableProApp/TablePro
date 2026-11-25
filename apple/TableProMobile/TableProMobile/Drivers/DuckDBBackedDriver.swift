import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProQuery

// The Mac's DuckDB plugin driver over a file this app holds access to: one in its own container, one the user picked
// (security-scoped) or an in-memory database. A transfer reads on a connection of its own to the session's database,
// since DuckDB opens a file once per process. The plugin writes no rows of its own, so edits take SQLBuilder's SQL.
nonisolated final class DuckDBBackedDriver: PluginBackedDriver, DedicatedTransferConnection, @unchecked Sendable {
    private let duck: DuckDBPluginDriver
    // Nil for a transfer connection, which lives and ends inside its session's database.
    private let source: LocalDatabaseFileSource?
    private let openMode: LocalDatabaseOpenMode
    private let fileAccess = LocalDatabaseFileAccess()

    convenience init(source: LocalDatabaseFileSource, openMode: LocalDatabaseOpenMode = .existingOnly) {
        self.init(
            duck: DuckDBPluginDriver(config: DuckDBBackedDriver.config(opening: source)), source: source, openMode: openMode
        )
    }

    private init(duck: DuckDBPluginDriver, source: LocalDatabaseFileSource?, openMode: LocalDatabaseOpenMode) {
        self.duck = duck
        self.source = source
        self.openMode = openMode
        super.init(
            plugin: duck,
            dialedHosts: [],
            readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .duckdb) },
            cancelsRunningRequest: { try? duck.cancelQuery() }
        )
    }

    // Only the file the app resolved: a connection from the Mac can carry a Mac path, Remote mode, attached databases
    // or an idle release, none of which this app opens.
    private static func config(opening source: LocalDatabaseFileSource) -> DriverConnectionConfig {
        let path: String
        switch source {
        case .inMemory: path = LocalDatabaseLocation.inMemoryPath
        case .file(let url), .securityScoped(let url): path = url.path
        }
        return DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: path,
            additionalFields: ["duckdbMode": "local", "duckdbFilePath": path]
        )
    }

    // The session holds the file; a transfer connection and an in-memory database hold none of their own.
    override var holdsSuspensionBlockingResource: Bool {
        guard let source else { return false }
        return source != .inMemory
    }

    override func connect() async throws {
        guard let source else { return }
        _ = try fileAccess.begin(source, openMode: openMode)
        do {
            try await super.connect()
        } catch {
            await duck.close()
            fileAccess.end()
            throw error
        }
    }

    // Access to a picked file ends only once DuckDB has closed it.
    override func disconnect() async throws {
        await duck.close()
        fileAccess.end()
    }

    // A transfer connection runs only its own transfer, so its Stop interrupts whatever it is reading.
    override func cancelCurrentQuery() async throws {
        guard source == nil else { return }
        try duck.cancelQuery()
    }

    // A read takes each batch as the plugin hands it out and cuts each value while it is decoded (`PluginGridCut`).
    override func stream(
        query: String,
        options: StreamOptions,
        bindsToSession: Bool
    ) -> AsyncThrowingStream<StreamElement, Error> {
        guard !SQLWriteClassifier.isWriteQuery(query, databaseType: .duckdb) else {
            return super.stream(query: query, options: options, bindsToSession: bindsToSession)
        }
        let duck = duck
        let context = statementContext(query)
        let read = Self.gridReader(options: options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.exclusively {
                        let sink = PluginGridSink(options: options, continuation: continuation)
                        batches: for try await element in duck.pulledValues(query: query, context: context, reading: read) {
                            switch element {
                            case .header(let header):
                                sink.begin(columns: header.columns, typeNames: header.columnTypeNames)
                            case .rows(let batch):
                                guard sink.emit(batch) else { break batches }
                            }
                        }
                        await duck.endPulledRows()
                    }
                    continuation.finish()
                } catch {
                    // A Stop interrupts the query, so its error is the Stop itself.
                    if error is CancellationError || Task.isCancelled {
                        continuation.yield(.truncated(reason: .cancelled))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func gridReader(options: StreamOptions) -> DuckDBValueReader<PluginGridValue> {
        let cut = PluginGridCut(options: options)
        return { column, value in
            switch value {
            case .null: .null
            case .spelled(let text): .text(text)
            case .bytes(let bytes): .bytes(count: bytes.count)
            case .text(let utf8): cut.text(utf8, column: column)
            }
        }
    }

    // A session export reads on a connection of its own, a batch per pull: one that streamed on the session would hold
    // the executor the session's next statement waits on, and a grid statement would end its result.
    override func exportRows(query: String, readOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard source != nil else { return super.exportRows(query: query, readOnly: readOnly) }
        var context = statementContext(query)
        context.readOnly = true
        context.enforcesReadOnly = readOnly
        let pull = DuckDBOwnedTransferRead(duck: duck, query: query, context: context)
        return AsyncThrowingStream(unfolding: { try await pull.next() })
    }

    func openTransferDriver() async throws -> any DatabaseDriver {
        guard source != nil else { return self }
        return DuckDBBackedDriver(duck: try await duck.openTransferDriver(), source: nil, openMode: .existingOnly)
    }
}

// The pull side of a session export: a transfer connection opened on the first pull and closed at the read's end, or
// by the stream's release.
nonisolated private final class DuckDBOwnedTransferRead: @unchecked Sendable {
    private let duck: DuckDBPluginDriver
    private let query: String
    private let context: PluginStatementContext
    private let lock = NSLock()
    private var transfer: DuckDBPluginDriver?
    private var rows: AsyncThrowingStream<PluginStreamElement, Error>.AsyncIterator?

    init(duck: DuckDBPluginDriver, query: String, context: PluginStatementContext) {
        self.duck = duck
        self.query = query
        self.context = context
    }

    deinit {
        guard let transfer = lock.withLock({ self.transfer }) else { return }
        Task { await transfer.close() }
    }

    func next() async throws -> PluginStreamElement? {
        do {
            var iterator = try await openedRows()
            let element = try await iterator.next()
            lock.withLock { rows = iterator }
            if element == nil { await end() }
            return element
        } catch {
            await end()
            throw error
        }
    }

    private func openedRows() async throws -> AsyncThrowingStream<PluginStreamElement, Error>.AsyncIterator {
        if let rows = lock.withLock({ self.rows }) { return rows }
        let opened = try await duck.openTransferDriver()
        lock.withLock { transfer = opened }
        return opened.pulledRows(query: query, context: context).makeAsyncIterator()
    }

    private func end() async {
        let ending = lock.withLock { () -> DuckDBPluginDriver? in
            defer {
                transfer = nil
                rows = nil
            }
            return transfer
        }
        await ending?.close()
    }
}
