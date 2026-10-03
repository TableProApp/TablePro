import Foundation

internal enum OracleQueryTimeout {
    internal static let maximumSeconds = Int(Int32.max) / 1_000

    internal static func boundedSeconds(_ seconds: Int) -> Int {
        min(max(seconds, 0), maximumSeconds)
    }

    internal static func nanoseconds(_ seconds: Double) -> UInt64 {
        guard !seconds.isNaN else { return 0 }
        let boundedSeconds = min(max(seconds, 0), Double(maximumSeconds))
        return UInt64(boundedSeconds * 1_000_000_000)
    }
}

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
            try await Task.sleep(nanoseconds: OracleQueryTimeout.nanoseconds(seconds))
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
