import Foundation

public enum OracleConnectFailure: Sendable, Equatable {
    case verifierUnsupported(flag: String)
    case versionNotSupported
    case connectionDropped
    case connectionFailed
    case advancedNegotiationFailed
    case advancedNegotiationRequired
    case loginHandshakeTimedOut
}

public enum OracleConnectErrorClassifier {
    public static func classify(_ codeDescription: String) -> OracleConnectFailure {
        if codeDescription.hasPrefix("unsupportedVerifierType") {
            return .verifierUnsupported(flag: codeDescription)
        }
        switch codeDescription {
        case "uncleanShutdown":
            return .connectionDropped
        case "serverVersionNotSupported":
            return .versionNotSupported
        case "advancedNegotiationFailed":
            return .advancedNegotiationFailed
        case "advancedNegotiationRequired":
            return .advancedNegotiationRequired
        case "loginHandshakeTimedOut":
            return .loginHandshakeTimedOut
        default:
            return .connectionFailed
        }
    }

    public static func isLikelyNativeEncryptionFailure(
        failure: OracleConnectFailure,
        nativeNetworkEncryptionEnabled: Bool,
        timedOut: Bool
    ) -> Bool {
        guard nativeNetworkEncryptionEnabled else { return false }
        switch failure {
        case .advancedNegotiationFailed, .advancedNegotiationRequired:
            return true
        case .connectionDropped, .connectionFailed:
            return timedOut
        case .verifierUnsupported, .versionNotSupported, .loginHandshakeTimedOut:
            return false
        }
    }
}

/// Which OracleNIO failures leave the channel unusable.
///
/// It mirrors OracleNIO's own `ConnectionStateMachine.shouldCloseConnection(reason:)`, which is
/// internal and so cannot be called. Disagreeing with it means the app keeps a channel OracleNIO
/// has already torn down, and the next statement on it fails for a reason nobody can act on. The
/// old three-code list did exactly that for a client-side close (#3053).
///
/// `clientClosesConnection` and `clientClosedConnection` are the two OracleNIO refuses to classify
/// at all, because it raises them only from `OracleConnection.close()`: by the time one exists the
/// channel is gone, so they are unambiguously fatal here.
public enum OracleChannelFatalCode {
    public static func isChannelFatal(_ codeDescription: String, serverErrorNumber: Int? = nil) -> Bool {
        if codeDescription.hasPrefix("unsupportedVerifierType") {
            return true
        }
        switch codeDescription {
        case "clientClosesConnection",
             "clientClosedConnection",
             "failedToAddSSLHandler",
             "failedToVerifyTLSCertificates",
             "connectionError",
             "messageDecodingFailure",
             "missingParameter",
             "unexpectedBackendMessage",
             "serverVersionNotSupported",
             "sidNotSupported",
             "uncleanShutdown",
             "unsupportedDataType",
             "advancedNegotiationFailed",
             "advancedNegotiationRequired",
             "loginHandshakeTimedOut":
            return true
        case "server":
            return serverErrorNumber == 28 || serverErrorNumber == 600
        default:
            return false
        }
    }

    /// What took the channel away, for a code ``isChannelFatal(_:serverErrorNumber:)`` calls fatal.
    ///
    /// The three read very differently to a user. A lost socket and a close from this side are both
    /// "the connection went away, run it again"; only a protocol failure is worth telling anyone
    /// the server sent something the driver could not read.
    public static func closureKind(_ codeDescription: String) -> OracleChannelClosureKind {
        switch codeDescription {
        case "clientClosesConnection", "clientClosedConnection":
            return .clientClose
        case "uncleanShutdown", "connectionError":
            return .transportLoss
        default:
            return .protocolFailure
        }
    }
}

public enum OracleChannelClosureKind: Sendable, Equatable {
    /// This side called `OracleConnection.close()` while the statement was on the wire.
    case clientClose
    /// The socket went away: the server, a VPN, or the OS closed it.
    case transportLoss
    /// The driver could not make sense of what came back.
    case protocolFailure
}

public enum OracleSSLClassifier {
    public static func classifyTLSFailure(_ message: String) -> OracleTLSFailureKind? {
        let lower = message.lowercased()
        if lower.contains("ora-28759") || lower.contains("failure to open file") && lower.contains("wallet") {
            return .clientCertRequired
        }
        if lower.contains("ora-29024") {
            return .cipherMismatch
        }
        if lower.contains("ora-28860") {
            return .cipherMismatch
        }
        if lower.contains("certificate") && (lower.contains("verify") || lower.contains("untrusted")) {
            return .untrustedCertificate
        }
        return nil
    }
}
