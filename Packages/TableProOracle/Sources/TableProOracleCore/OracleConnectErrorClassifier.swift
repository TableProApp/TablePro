import Foundation

public enum OracleConnectFailure: Sendable, Equatable {
    case verifierUnsupported(flag: String)
    case versionNotSupported
    case connectionDropped
    case connectionFailed
    case advancedNegotiationFailed
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
        case .advancedNegotiationFailed:
            return true
        case .connectionDropped, .connectionFailed:
            return timedOut
        case .verifierUnsupported, .versionNotSupported:
            return false
        }
    }
}

public enum OracleChannelFatalCode {
    public static func isChannelFatal(_ codeDescription: String) -> Bool {
        switch codeDescription {
        case "connectionError", "messageDecodingFailure", "unexpectedBackendMessage":
            return true
        default:
            return false
        }
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
