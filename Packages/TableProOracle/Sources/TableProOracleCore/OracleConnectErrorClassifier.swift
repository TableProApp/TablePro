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

    /// Whether this side closed the channel, rather than the server or the protocol failing.
    public static func isClientClose(_ codeDescription: String) -> Bool {
        codeDescription == "clientClosesConnection" || codeDescription == "clientClosedConnection"
    }
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
