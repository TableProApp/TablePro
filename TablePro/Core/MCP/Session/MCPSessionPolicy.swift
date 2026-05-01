import Foundation

public struct MCPSessionPolicy: Sendable, Equatable {
    public let idleTimeout: Duration
    public let maxSessions: Int
    public let cleanupInterval: Duration

    public init(idleTimeout: Duration, maxSessions: Int, cleanupInterval: Duration) {
        self.idleTimeout = idleTimeout
        self.maxSessions = maxSessions
        self.cleanupInterval = cleanupInterval
    }

    public static let standard = MCPSessionPolicy(
        idleTimeout: .seconds(900),
        maxSessions: 16,
        cleanupInterval: .seconds(60)
    )
}
