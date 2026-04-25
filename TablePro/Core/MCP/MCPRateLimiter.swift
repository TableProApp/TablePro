import Foundation
import os

actor MCPRateLimiter {
    enum AuthRateResult: Sendable {
        case allowed
        case rateLimited(retryAfter: Duration)
    }

    private struct FailureRecord {
        var consecutiveFailures: Int
        var lockedUntil: ContinuousClock.Instant?
        var lastUpdated: ContinuousClock.Instant
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPRateLimiter")

    private static let staleEntryThreshold: Duration = .seconds(600)
    private static let cleanupInterval: Duration = .seconds(300)

    private var records: [String: FailureRecord] = [:]
    private var lastCleanup: ContinuousClock.Instant = .now

    func checkAndRecord(ip: String, success: Bool) -> AuthRateResult {
        cleanupStaleEntriesIfNeeded()

        let now = ContinuousClock.now

        if let record = records[ip], let lockedUntil = record.lockedUntil, now < lockedUntil {
            let remaining = lockedUntil - now
            return .rateLimited(retryAfter: remaining)
        }

        guard !success else {
            records.removeValue(forKey: ip)
            return .allowed
        }

        var record = records[ip] ?? FailureRecord(consecutiveFailures: 0, lockedUntil: nil, lastUpdated: now)
        record.consecutiveFailures += 1
        record.lastUpdated = now

        let lockoutDuration = lockoutDuration(forFailureCount: record.consecutiveFailures)
        if let lockout = lockoutDuration {
            record.lockedUntil = now + lockout
            records[ip] = record
            return .rateLimited(retryAfter: lockout)
        }

        record.lockedUntil = nil
        records[ip] = record
        return .allowed
    }

    func isLockedOut(ip: String) -> AuthRateResult {
        let now = ContinuousClock.now
        guard let record = records[ip], let lockedUntil = record.lockedUntil, now < lockedUntil else {
            return .allowed
        }
        return .rateLimited(retryAfter: lockedUntil - now)
    }

    private func lockoutDuration(forFailureCount count: Int) -> Duration? {
        switch count {
        case 1:
            return nil
        case 2:
            return .seconds(1)
        case 3:
            return .seconds(5)
        case 4:
            return .seconds(30)
        default:
            return .seconds(300)
        }
    }

    private func cleanupStaleEntriesIfNeeded() {
        let now = ContinuousClock.now
        guard now - lastCleanup > Self.cleanupInterval else { return }

        lastCleanup = now
        let threshold = now - Self.staleEntryThreshold

        let staleKeys = records.filter { $0.value.lastUpdated < threshold }.map(\.key)
        for key in staleKeys {
            records.removeValue(forKey: key)
        }

        if !staleKeys.isEmpty {
            Self.logger.info("Cleaned up \(staleKeys.count) stale rate limit entries")
        }
    }
}
