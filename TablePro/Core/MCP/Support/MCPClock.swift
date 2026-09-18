import Foundation

public protocol MCPClock: Sendable {
    func now() async -> Date
    func sleep(for duration: Duration) async throws
}

public struct MCPSystemClock: MCPClock {
    public init() {}

    public func now() async -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
