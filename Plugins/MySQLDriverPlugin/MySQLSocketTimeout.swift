//
//  MySQLSocketTimeout.swift
//  MySQLDriverPlugin
//

import Foundation

internal struct MySQLConnectTimeout: Equatable, Sendable {
    static let defaultMilliseconds = 30_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: Int

    init(additionalFields: [String: String]) {
        milliseconds = Self.resolve(additionalFields: additionalFields)
    }

    init(milliseconds: Int) {
        self.milliseconds = min(max(milliseconds, 1), Self.maximumMilliseconds)
    }

    var nativeSeconds: UInt32 {
        UInt32((milliseconds + 999) / 1_000)
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

internal struct MySQLConnectDeadline: Equatable, Sendable {
    private let expiration: ContinuousClock.Instant

    init(
        timeout: MySQLConnectTimeout,
        startedAt: ContinuousClock.Instant = .now
    ) {
        expiration = startedAt.advanced(by: .milliseconds(timeout.milliseconds))
    }

    func remainingMilliseconds(at now: ContinuousClock.Instant = .now) -> Int? {
        guard now < expiration else { return nil }
        let components = now.duration(to: expiration).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(1, Int(milliseconds.rounded(.up)))
    }

    func socketTimeoutSeconds(at now: ContinuousClock.Instant = .now) -> UInt32? {
        remainingMilliseconds(at: now).map { MySQLConnectTimeout(milliseconds: $0).nativeSeconds }
    }
}

internal let mysqlSocketTimeoutGraceSeconds = 30

internal func mysqlSocketTimeoutSeconds(forQueryTimeout queryTimeoutSeconds: Int) -> UInt32 {
    guard queryTimeoutSeconds > 0 else { return 0 }
    let ceiling = Int(UInt32.max) - mysqlSocketTimeoutGraceSeconds
    let clamped = min(queryTimeoutSeconds, ceiling)
    return UInt32(clamped + mysqlSocketTimeoutGraceSeconds)
}

/// Whether a failure this long into a statement could be the client's own read timeout rather than
/// the server dropping the connection. `MYSQL_OPT_READ_TIMEOUT` needs that much silence before it
/// fires, so anything earlier is never ours.
internal func mysqlWaitCouldOutlastSocketTimeout(
    _ waited: Duration,
    socketTimeoutSeconds: UInt32
) -> Bool {
    guard socketTimeoutSeconds > 0 else { return false }
    return waited >= .seconds(Int64(socketTimeoutSeconds))
}
