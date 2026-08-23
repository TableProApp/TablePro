import Foundation

public struct MCPLegacySessionPolicy: Sendable, Equatable {
    public let idleTimeout: Duration
    public let maxSessions: Int
    public let sweepInterval: Duration

    public init(idleTimeout: Duration, maxSessions: Int, sweepInterval: Duration) {
        self.idleTimeout = idleTimeout
        self.maxSessions = max(1, maxSessions)
        self.sweepInterval = sweepInterval
    }

    public static let standard = MCPLegacySessionPolicy(
        idleTimeout: .seconds(900),
        maxSessions: 16,
        sweepInterval: .seconds(60)
    )

    public var idleTimeoutSeconds: TimeInterval {
        Self.seconds(of: idleTimeout)
    }

    public var sweepIntervalSeconds: TimeInterval {
        Self.seconds(of: sweepInterval)
    }

    public static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}
