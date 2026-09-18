import Foundation
import os

public enum MCPRateLimitSubject: Sendable, Equatable, Hashable {
    case address(MCPClientAddress)
    case token(UUID)

    public var describedValue: String {
        switch self {
        case .address(let address):
            return "address:\(address.displayValue)"
        case .token(let tokenId):
            return "token:\(tokenId.uuidString)"
        }
    }
}

public enum MCPRateLimitDimension: String, Sendable, Equatable, Hashable, CaseIterable {
    case authFailure
    case pairingExchange
}

public struct MCPRateLimitKey: Sendable, Equatable, Hashable {
    public let subject: MCPRateLimitSubject
    public let dimension: MCPRateLimitDimension

    public init(subject: MCPRateLimitSubject, dimension: MCPRateLimitDimension) {
        self.subject = subject
        self.dimension = dimension
    }

    public static func authFailure(address: MCPClientAddress) -> Self {
        Self(subject: .address(address), dimension: .authFailure)
    }

    public static func authFailure(tokenId: UUID) -> Self {
        Self(subject: .token(tokenId), dimension: .authFailure)
    }

    public static func pairingExchange(address: MCPClientAddress) -> Self {
        Self(subject: .address(address), dimension: .pairingExchange)
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

public struct MCPRequestRatePolicy: Sendable, Equatable {
    public let maxRequests: Int
    public let windowDuration: Duration
    public let maxConcurrentRequests: Int

    public init(maxRequests: Int, windowDuration: Duration, maxConcurrentRequests: Int) {
        self.maxRequests = maxRequests
        self.windowDuration = windowDuration
        self.maxConcurrentRequests = maxConcurrentRequests
    }

    public static let standard = MCPRequestRatePolicy(
        maxRequests: 240,
        windowDuration: .seconds(60),
        maxConcurrentRequests: 8
    )
}

public enum MCPRateLimitVerdict: Sendable, Equatable {
    case allowed
    case lockedUntil(Date)
}

public enum MCPRequestRejectionReason: String, Sendable, Equatable {
    case rateExceeded
    case concurrencyExceeded
}

public enum MCPRequestAdmission: Sendable, Equatable {
    case admitted
    case rejected(retryAfterSeconds: Int, reason: MCPRequestRejectionReason)
}

public actor MCPRateLimiter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.RateLimit")

    private struct FailureBucket {
        var failureTimestamps: [Date]
        var lockedUntil: Date?
    }

    private struct RequestBucket {
        var timestamps: [Date]
        var inFlight: Int
    }

    private let policy: MCPRateLimitPolicy
    private let pairingPolicy: MCPRateLimitPolicy
    private let requestPolicy: MCPRequestRatePolicy
    private let clock: any MCPClock
    private var failureBuckets: [MCPRateLimitKey: FailureBucket] = [:]
    private var requestBuckets: [MCPRateLimitSubject: RequestBucket] = [:]

    public init(
        policy: MCPRateLimitPolicy = .standard,
        pairingPolicy: MCPRateLimitPolicy = .standard,
        requestPolicy: MCPRequestRatePolicy = .standard,
        clock: any MCPClock = MCPSystemClock()
    ) {
        self.policy = policy
        self.pairingPolicy = pairingPolicy
        self.requestPolicy = requestPolicy
        self.clock = clock
    }

    public func recordAttempt(key: MCPRateLimitKey, success: Bool) async -> MCPRateLimitVerdict {
        let now = await clock.now()
        let activePolicy = failurePolicy(for: key.dimension)

        if let lockedUntil = failureBuckets[key]?.lockedUntil, lockedUntil > now {
            return .lockedUntil(lockedUntil)
        }

        if success {
            failureBuckets.removeValue(forKey: key)
            return .allowed
        }

        var bucket = failureBuckets[key] ?? FailureBucket(failureTimestamps: [], lockedUntil: nil)
        let windowStart = now.addingTimeInterval(-Self.seconds(of: activePolicy.windowDuration))
        bucket.failureTimestamps.removeAll { $0 < windowStart }
        bucket.failureTimestamps.append(now)

        if bucket.failureTimestamps.count >= activePolicy.maxFailedAttempts {
            let lockUntil = now.addingTimeInterval(Self.seconds(of: activePolicy.lockoutDuration))
            bucket.lockedUntil = lockUntil
            failureBuckets[key] = bucket
            Self.logger.warning(
                "Rate limit lockout \(Self.describe(key), privacy: .public) until \(lockUntil, privacy: .public)"
            )
            return .lockedUntil(lockUntil)
        }

        bucket.lockedUntil = nil
        failureBuckets[key] = bucket
        return .allowed
    }

    public func isLocked(key: MCPRateLimitKey) async -> Bool {
        guard let lockedUntil = failureBuckets[key]?.lockedUntil else { return false }
        return lockedUntil > (await clock.now())
    }

    public func lockedUntil(key: MCPRateLimitKey) async -> Date? {
        guard let lockedUntil = failureBuckets[key]?.lockedUntil else { return nil }
        guard lockedUntil > (await clock.now()) else { return nil }
        return lockedUntil
    }

    public func retryAfterSeconds(until unlockDate: Date) async -> Int {
        let now = await clock.now()
        let delta = unlockDate.timeIntervalSince(now)
        guard delta > 0 else { return 1 }
        return max(1, Int(delta.rounded(.up)))
    }

    public func reset(key: MCPRateLimitKey) async {
        failureBuckets.removeValue(forKey: key)
    }

    public func admit(subject: MCPRateLimitSubject) async -> MCPRequestAdmission {
        let now = await clock.now()
        var bucket = requestBuckets[subject] ?? RequestBucket(timestamps: [], inFlight: 0)
        let windowStart = now.addingTimeInterval(-Self.seconds(of: requestPolicy.windowDuration))
        bucket.timestamps.removeAll { $0 < windowStart }

        if bucket.inFlight >= requestPolicy.maxConcurrentRequests {
            requestBuckets[subject] = bucket
            Self.logger.warning(
                "Concurrency limit reached for \(subject.describedValue, privacy: .public)"
            )
            return .rejected(retryAfterSeconds: 1, reason: .concurrencyExceeded)
        }

        if bucket.timestamps.count >= requestPolicy.maxRequests {
            let oldest = bucket.timestamps.first ?? now
            let freesAt = oldest.addingTimeInterval(Self.seconds(of: requestPolicy.windowDuration))
            requestBuckets[subject] = bucket
            Self.logger.warning(
                "Request rate limit reached for \(subject.describedValue, privacy: .public)"
            )
            return .rejected(
                retryAfterSeconds: await retryAfterSeconds(until: freesAt),
                reason: .rateExceeded
            )
        }

        bucket.timestamps.append(now)
        bucket.inFlight += 1
        requestBuckets[subject] = bucket
        return .admitted
    }

    public func release(subject: MCPRateLimitSubject) async {
        guard var bucket = requestBuckets[subject] else { return }
        bucket.inFlight = max(0, bucket.inFlight - 1)
        if bucket.inFlight == 0, bucket.timestamps.isEmpty {
            requestBuckets.removeValue(forKey: subject)
            return
        }
        requestBuckets[subject] = bucket
    }

    public func inFlightCount(subject: MCPRateLimitSubject) async -> Int {
        requestBuckets[subject]?.inFlight ?? 0
    }

    public func clearAll() async {
        failureBuckets.removeAll()
        requestBuckets.removeAll()
    }

    private func failurePolicy(for dimension: MCPRateLimitDimension) -> MCPRateLimitPolicy {
        switch dimension {
        case .authFailure:
            return policy
        case .pairingExchange:
            return pairingPolicy
        }
    }

    private static func describe(_ key: MCPRateLimitKey) -> String {
        "\(key.dimension.rawValue)/\(key.subject.describedValue)"
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}

public extension MCPRateLimiter {
    nonisolated func withRequestSlot<T>(
        subject: MCPRateLimitSubject,
        operation: () async throws -> T
    ) async throws -> T {
        switch await admit(subject: subject) {
        case .admitted:
            break
        case .rejected(let retryAfterSeconds, _):
            throw MCPProtocolError.rateLimited(retryAfterSeconds: retryAfterSeconds)
        }
        do {
            let value = try await operation()
            await release(subject: subject)
            return value
        } catch {
            await release(subject: subject)
            throw error
        }
    }
}
