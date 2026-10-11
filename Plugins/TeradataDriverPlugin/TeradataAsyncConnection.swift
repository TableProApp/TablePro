import Foundation
import TableProTeradataCore

final class TeradataAsyncConnection: @unchecked Sendable {
    private let connection: TeradataConnection
    private let queue = DispatchQueue(label: "com.TablePro.teradata.connection")

    init(config: TeradataConnectionConfig) {
        connection = TeradataConnection(config: config)
    }

    var isConnected: Bool {
        queue.sync { connection.isConnected }
    }

    func connect() async throws {
        try await run { try $0.connect() }
    }

    func finishConnecting() async throws {
        try await run { try $0.finishConnecting() }
    }

    func execute(_ sql: String) async throws -> TeradataResultSet {
        try await run { try $0.execute(sql) }
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
                    do {
                        try cancellation.throwIfCancelled()
                        let value = try body(self.connection)
                        try cancellation.throwIfCancelled()
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            // TeradataConnection snapshots its transport under a lock; the transport's cancel
            // path uses shutdown rather than disconnecting concurrently with protocol cleanup.
            connection.cancel()
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
