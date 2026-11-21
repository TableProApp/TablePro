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

    // A read takes each batch as the plugin hands it out and cuts it for display before the next, so a long text or
    // BLOB column is never held whole for every row of the result.
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.exclusively {
                        var rows = PluginRowEmitter(options: options)
                        read: for try await element in duck.pulledRows(query: query, context: context) {
                            switch element {
                            case .header(let header):
                                rows.begin(columns: header.columns, typeNames: header.columnTypeNames, into: continuation)
                            case .rows(let batch):
                                for row in batch {
                                    guard rows.emit(row, locator: nil, into: continuation) else { break read }
                                }
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

    func openTransferDriver() async throws -> any DatabaseDriver {
        guard source != nil else { return self }
        return DuckDBBackedDriver(duck: try await duck.openTransferDriver(), source: nil, openMode: .existingOnly)
    }
}
