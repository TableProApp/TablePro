import Foundation

enum PluginConnectTimeout {
    static let maximumMilliseconds = 3_600_000

    static func milliseconds(
        in additionalFields: [String: String],
        default defaultMilliseconds: Int
    ) -> Int {
        if let rawMilliseconds = additionalFields["connectTimeoutMilliseconds"],
           let milliseconds = parsedMilliseconds(rawMilliseconds, multiplier: 1)
        {
            return milliseconds
        }
        if let rawSeconds = additionalFields["connectTimeoutSeconds"],
           let milliseconds = parsedMilliseconds(rawSeconds, multiplier: 1_000)
        {
            return milliseconds
        }
        return defaultMilliseconds
    }

    static func seconds(
        in additionalFields: [String: String],
        default defaultSeconds: TimeInterval
    ) -> TimeInterval {
        let defaultMilliseconds = Int(defaultSeconds * 1_000)
        return TimeInterval(milliseconds(in: additionalFields, default: defaultMilliseconds)) / 1_000
    }

    private static func parsedMilliseconds(_ rawValue: String, multiplier: Double) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        let milliseconds = min(value * multiplier, Double(maximumMilliseconds))
        return max(1, Int(milliseconds.rounded(.towardZero)))
    }
}

struct PluginConnectDeadline: Sendable {
    private let expiration: ContinuousClock.Instant

    init(milliseconds: Int, now: ContinuousClock.Instant = .now) {
        expiration = now.advanced(by: .milliseconds(milliseconds))
    }

    func remainingMilliseconds(at now: ContinuousClock.Instant = .now) -> Int {
        guard now < expiration else { return 1 }
        let components = now.duration(to: expiration).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(1, min(PluginConnectTimeout.maximumMilliseconds, Int(milliseconds.rounded(.up))))
    }

    func remainingSeconds(at now: ContinuousClock.Instant = .now) -> TimeInterval {
        TimeInterval(remainingMilliseconds(at: now)) / 1_000
    }
}

struct PluginAWSConnectSessionBudget: Equatable, Sendable {
    /// Kept in sync with the internal parser in TableProPluginKit/AWS/AWSHTTP.swift. This is
    /// URLSession metadata only; it is never sent to AWS as a header and adds no PluginKit ABI.
    private static let sessionDescriptionPrefix = "com.tablepro.aws-connect-deadline-v1:"

    let remainingSeconds: TimeInterval
    let expiresAtUptime: TimeInterval

    init(
        deadline: PluginConnectDeadline,
        now: ContinuousClock.Instant = .now,
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let remaining = deadline.remainingSeconds(at: now)
        remainingSeconds = remaining
        expiresAtUptime = systemUptime + remaining
    }

    init?(expiresAtUptime: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let remaining = expiresAtUptime - now
        guard remaining > 0 else { return nil }
        remainingSeconds = max(remaining, 0.001)
        self.expiresAtUptime = expiresAtUptime
    }

    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = remainingSeconds
        configuration.timeoutIntervalForResource = remainingSeconds
        let session = URLSession(configuration: configuration)
        session.sessionDescription = Self.sessionDescriptionPrefix + String(expiresAtUptime)
        return session
    }
}

final class PluginConnectTimeoutPhase: @unchecked Sendable {
    private let deadline: PluginConnectDeadline
    private let lock = NSLock()
    private var isConnecting = true

    init(deadline: PluginConnectDeadline) {
        self.deadline = deadline
    }

    func remainingSeconds(or fallback: TimeInterval) -> TimeInterval {
        lock.lock()
        let connecting = isConnecting
        lock.unlock()
        return connecting ? deadline.remainingSeconds() : fallback
    }

    func finish() {
        lock.lock()
        isConnecting = false
        lock.unlock()
    }
}
