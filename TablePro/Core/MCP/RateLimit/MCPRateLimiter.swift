import Foundation
import os

public struct MCPRateLimitKey: Sendable, Equatable, Hashable {
    public let clientAddress: MCPClientAddress
    public let principalFingerprint: String?

    public init(clientAddress: MCPClientAddress, principalFingerprint: String?) {
        self.clientAddress = clientAddress
        self.principalFingerprint = principalFingerprint
    }
}

public struct MCPRateLimitPolicy: Sendable, Equatable {
    public let maxFailedAttempts: Int
    public let windowDuration: Duration
    public let lockoutDuration: Duration

    public init(maxFailedAttempts: Int, windowDuration: Duration, lockoutDuration: Duration) {
        self.maxFailedAttempts = maxFailedAttempts
        self.windowDuration = windowDuration
        self.lockoutDuration = lockoutDuration
    }

    public static let standard = MCPRateLimitPolicy(
        maxFailedAttempts: 5,
        windowDuration: .seconds(60),
        lockoutDuration: .seconds(300)
    )
}

public enum MCPRateLimitVerdict: Sendable, Equatable {
    case allowed
    case lockedUntil(Date)
}

public actor MCPRateLimiter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.RateLimit")

    private struct Bucket {
        var failureTimestamps: [Date]
        var lockedUntil: Date?
    }

    private let policy: MCPRateLimitPolicy
    private let clock: any MCPClock
    private var buckets: [MCPRateLimitKey: Bucket] = [:]

    public init(policy: MCPRateLimitPolicy = .standard, clock: any MCPClock = MCPSystemClock()) {
        self.policy = policy
        self.clock = clock
    }

    public func recordAttempt(key: MCPRateLimitKey, success: Bool) async -> MCPRateLimitVerdict {
        let now = await clock.now()

        if let lockedUntil = buckets[key]?.lockedUntil, lockedUntil > now {
            return .lockedUntil(lockedUntil)
        }

        if success {
            buckets.removeValue(forKey: key)
            return .allowed
        }

        var bucket = buckets[key] ?? Bucket(failureTimestamps: [], lockedUntil: nil)
        let windowStart = now.addingTimeInterval(-Self.seconds(of: policy.windowDuration))
        bucket.failureTimestamps.removeAll { $0 < windowStart }
        bucket.failureTimestamps.append(now)

        if bucket.failureTimestamps.count >= policy.maxFailedAttempts {
            let lockUntil = now.addingTimeInterval(Self.seconds(of: policy.lockoutDuration))
            bucket.lockedUntil = lockUntil
            buckets[key] = bucket
            Self.logger.warning(
                "Rate limit lockout \(Self.describe(key), privacy: .public) until \(lockUntil, privacy: .public)"
            )
            return .lockedUntil(lockUntil)
        }

        bucket.lockedUntil = nil
        buckets[key] = bucket
        return .allowed
    }

    public func isLocked(key: MCPRateLimitKey) async -> Bool {
        guard let lockedUntil = buckets[key]?.lockedUntil else { return false }
        return lockedUntil > (await clock.now())
    }

    public func lockedUntil(key: MCPRateLimitKey) async -> Date? {
        guard let lockedUntil = buckets[key]?.lockedUntil else { return nil }
        guard lockedUntil > (await clock.now()) else { return nil }
        return lockedUntil
    }

    public func reset(key: MCPRateLimitKey) async {
        buckets.removeValue(forKey: key)
    }

    private static func describe(_ key: MCPRateLimitKey) -> String {
        let address: String
        switch key.clientAddress {
        case .loopback:
            address = "loopback"
        case .remote(let value):
            address = value
        }
        return "\(address)/\(key.principalFingerprint ?? "anon")"
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}
