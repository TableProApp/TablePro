import Foundation

nonisolated struct RedisConnectTimeout: Equatable, Sendable {
    static let defaultMilliseconds = 10_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: Int

    init(additionalFields: [String: String]) {
        milliseconds = Self.resolve(additionalFields: additionalFields)
    }

    init(milliseconds: Int) {
        self.milliseconds = min(max(milliseconds, 1), Self.maximumMilliseconds)
    }

    var timeInterval: TimeInterval {
        TimeInterval(milliseconds) / 1_000
    }

    private static func resolve(additionalFields: [String: String]) -> Int {
        if let rawMilliseconds = additionalFields["connectTimeoutMilliseconds"],
           let parsedMilliseconds = Int64(rawMilliseconds.trimmingCharacters(in: .whitespaces)) {
            return clamp(parsedMilliseconds)
        }
        if let rawSeconds = additionalFields["connectTimeoutSeconds"],
           let parsedSeconds = Int64(rawSeconds.trimmingCharacters(in: .whitespaces)) {
            let multiplied = parsedSeconds.multipliedReportingOverflow(by: 1_000)
            let milliseconds = multiplied.overflow
                ? (parsedSeconds < 0 ? Int64.min : Int64.max)
                : multiplied.partialValue
            return clamp(milliseconds)
        }
        return defaultMilliseconds
    }

    private static func clamp(_ milliseconds: Int64) -> Int {
        Int(min(max(milliseconds, 1), Int64(maximumMilliseconds)))
    }
}

nonisolated struct RedisConnectDeadline: Sendable {
    private let expiresAt: TimeInterval

    init(timeout: RedisConnectTimeout, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expiresAt = now + timeout.timeInterval
    }

    func remainingMilliseconds(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        let remaining = Int(((expiresAt - now) * 1_000).rounded(.up))
        return remaining > 0 ? remaining : nil
    }

    func socketTimeout(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RedisSocketTimeout? {
        guard let milliseconds = remainingMilliseconds(now: now) else { return nil }
        return RedisSocketTimeout(
            seconds: milliseconds / 1_000,
            microseconds: (milliseconds % 1_000) * 1_000
        )
    }
}

nonisolated struct RedisSocketTimeout: Equatable, Sendable {
    let seconds: Int
    let microseconds: Int
}

/// Whether a connection carries an identity, asked of the server rather than assumed.
///
/// A hiredis context that opened proves a reachable port and nothing else: an unauthenticated
/// connection accepts the socket and refuses every command, so "connected" has to be a reply the
/// server sent, not the absence of a transport error.
///
/// The reply cannot simply be tested for success. `PING`, `INFO` and `ACL WHOAMI` are all
/// ACL-deniable, so a restricted user answers `NOPERM` to whichever one is used as the probe, and
/// treating that as a failure locks out exactly the accounts ACLs exist to create. Measured
/// against Redis 8.10.1: an unauthenticated session gets `NOAUTH` from every command, while a
/// session bound to a user without `+ping` gets `NOPERM` and can still run what it is allowed.
/// `NOPERM` is therefore the server confirming an identity, and `NOAUTH` is the only reply that
/// says there is none.
nonisolated enum RedisConnectProbe {
    enum Outcome: Equatable, Sendable {
        case established
        case unauthenticated
        case refused(String)
    }

    static let command = ["PING"]

    static let unauthenticatedMessage = String(localized: "This server requires authentication.")
    static let unauthenticatedHint = String(
        localized: "Fill in Password, and Username too if the server uses Redis 6 ACL users."
    )

    static func outcome(errorMessage: String?) -> Outcome {
        guard let errorMessage, !errorMessage.isEmpty else { return .established }
        switch errorClass(of: errorMessage) {
        case "NOAUTH": return .unauthenticated
        case "NOPERM": return .established
        default: return .refused(errorMessage)
        }
    }

    /// RESP puts the error class in the first word, so the class is compared whole. A prefix test
    /// would let a future `NOAUTHZ` read as `NOAUTH`.
    static func errorClass(of message: String) -> String {
        String(message.prefix { !$0.isWhitespace }).uppercased()
    }
}

nonisolated extension RedisConnectProbe.Outcome {
    var failureMessage: String? {
        switch self {
        case .established:
            return nil
        case .unauthenticated:
            return RedisConnectProbe.unauthenticatedMessage
        case .refused(let serverError):
            return String(format: String(localized: "PING failed: %@"), serverError)
        }
    }

    var failureHint: String? {
        switch self {
        case .unauthenticated:
            return RedisConnectProbe.unauthenticatedHint
        case .established, .refused:
            return nil
        }
    }
}
