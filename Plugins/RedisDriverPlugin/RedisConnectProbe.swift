import Foundation

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
    private static func errorClass(of message: String) -> String {
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
