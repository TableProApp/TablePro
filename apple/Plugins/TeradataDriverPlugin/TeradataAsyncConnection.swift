import Foundation
import TableProPluginKit
import TableProTeradataCore

final class TeradataAsyncConnection: @unchecked Sendable {
    private let connection: TeradataConnection
    private let queue = DispatchQueue(label: "com.TablePro.teradata.connection")
    private let runningLock = NSLock()
    private var running: TeradataAsyncCancellation?

    init(config: TeradataConnectionConfig) {
        connection = TeradataConnection(config: config)
    }

    var isConnected: Bool {
        queue.sync { connection.isConnected }
    }

    // Read outside the queue, so asking never waits behind a running statement.
    var hasLostConnection: Bool { connection.hasLostConnection }

    var transactionState: TeradataTransactionState { connection.transactionState }

    var sessionTransactionMode: TeradataTransactionMode { connection.sessionTransactionMode }

    var sessionModeSource: TeradataSessionModeSource { connection.sessionModeSource }

    func connect() async throws {
        try await run { try $0.connect() }
    }

    func finishConnecting() async throws {
        try await run { try $0.finishConnecting() }
    }

    func execute(_ sql: String) async throws -> TeradataResultSet {
        try await run { try $0.execute(sql) }
    }

    func execute(_ sql: String, rowCap: Int?) async throws -> TeradataCappedResult {
        try await run { try $0.execute(sql, rowCap: rowCap) }
    }

    // One queue item for the whole answer: the session holds one request, so no other call may run between its replies.
    func stream(
        _ sql: String,
        onColumns: @escaping @Sendable ([TeradataColumn]) throws -> Void,
        onRows: @escaping @Sendable ([[TeradataValue]]) throws -> Bool
    ) async throws {
        try await run { try $0.stream(sql, onColumns: onColumns, onRows: onRows) }
    }

    func beginTransaction() async throws {
        try await run { try $0.beginTransaction() }
    }

    func commitTransaction() async throws {
        try await run { try $0.commitTransaction() }
    }

    func rollbackTransaction() async throws {
        try await run { try $0.rollbackTransaction() }
    }

    func switchDatabase(to database: String) async throws {
        try await run { try $0.switchDatabase(to: database) }
    }

    func disconnect() {
        queue.sync { connection.disconnect() }
    }

    func cancel() {
        connection.cancel()
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (TeradataConnection) throws -> T) async throws -> T {
        let cancellation = TeradataAsyncCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    // Begun before the call is marked running, so a Stop either side of the mark reaches it.
                    self.connection.beginOperation()
                    self.runningLock.withLock { self.running = cancellation }
                    defer {
                        self.runningLock.withLock { self.running = nil }
                        self.connection.endOperation()
                    }
                    do {
                        try cancellation.throwIfCancelled()
                        let value = try body(self.connection)
                        try cancellation.throwIfCancelled()
                        continuation.resume(returning: value)
                    } catch TeradataWireError.rolledBackByStop {
                        // Kept past the cancel, so the host can say what the Stop undid.
                        continuation.resume(throwing: PluginStopRolledBackTransaction(code: TeradataConnection.userAbortCode))
                    } catch {
                        continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            // A call still queued never starts; stopping the connection would stop the request of the one running.
            // Held across the stop, so the call cannot end and hand the session to the next one meanwhile.
            runningLock.withLock {
                guard running === cancellation else { return }
                connection.cancel()
            }
        }
    }
}

private final class TeradataAsyncCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}
