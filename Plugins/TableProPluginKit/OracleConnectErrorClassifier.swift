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
