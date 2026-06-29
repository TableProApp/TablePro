import Foundation

public struct TimeoutError: Error, Sendable, Equatable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TimeoutError(seconds: seconds)
        }
        return result
    }
}
