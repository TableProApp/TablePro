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
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body(self.connection))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
