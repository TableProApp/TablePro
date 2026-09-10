import Foundation

public struct OracleTimeoutError: Error, Sendable, Equatable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

public func withOracleTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withOracleTimeout(seconds: seconds, onTimeout: {}, operation: operation)
}

/// The task group waits for the operation child even after the deadline fires,
/// so `onTimeout` must force the operation to complete (close a connection,
/// fail a promise) when the wrapped call does not respond to task cancellation.
public func withOracleTimeout<T: Sendable>(
    seconds: Double,
    onTimeout: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw OracleTimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw OracleTimeoutError(seconds: seconds)
        }
        return result
    }
}
