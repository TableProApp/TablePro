import Foundation

struct CassandraConnectTimeout: Equatable, Sendable {
    struct NativeConfiguration: Equatable, Sendable {
        let connectMilliseconds: UInt32
        let resolveMilliseconds: UInt32
        let waitMicroseconds: UInt64
    }

    static let defaultMilliseconds = 10_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: UInt32

    init(additionalFields: [String: String]) {
        milliseconds = UInt32(Self.resolve(additionalFields: additionalFields))
    }

    init(milliseconds: Int) {
        self.milliseconds = UInt32(min(max(milliseconds, 1), Self.maximumMilliseconds))
    }

    var nativeConfiguration: NativeConfiguration {
        NativeConfiguration(
            connectMilliseconds: milliseconds,
            resolveMilliseconds: milliseconds,
            waitMicroseconds: UInt64(milliseconds) * 1_000
        )
    }

    private static func resolve(additionalFields: [String: String]) -> Int {
        if let rawMilliseconds = additionalFields["connectTimeoutMilliseconds"],
           let parsedMilliseconds = Int64(rawMilliseconds.trimmingCharacters(in: .whitespaces)) {
            return clamp(parsedMilliseconds)
        }
        if let rawSeconds = additionalFields["connectTimeoutSeconds"],
           let parsedSeconds = Int64(rawSeconds.trimmingCharacters(in: .whitespaces)) {
            let multiplied = parsedSeconds.multipliedReportingOverflow(by: 1_000)
            return clamp(multiplied.overflow ? Int64.max : multiplied.partialValue)
        }
        return defaultMilliseconds
    }

    private static func clamp(_ milliseconds: Int64) -> Int {
        Int(min(max(milliseconds, 1), Int64(maximumMilliseconds)))
    }
}

struct CassandraConnectDeadline: Sendable {
    private let expiresAt: TimeInterval

    init(timeout: CassandraConnectTimeout, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expiresAt = now + TimeInterval(timeout.milliseconds) / 1_000
    }

    func remainingMilliseconds(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UInt32? {
        let remaining = Int(((expiresAt - now) * 1_000).rounded(.up))
        guard remaining > 0 else { return nil }
        return UInt32(min(remaining, CassandraConnectTimeout.maximumMilliseconds))
    }

    func awsSessionBudget(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> PluginAWSConnectSessionBudget? {
        PluginAWSConnectSessionBudget(expiresAtUptime: expiresAt, now: now)
    }
}
