import Foundation

public enum OracleConnectFailure: Sendable, Equatable {
    case verifierUnsupported(flag: String)
    case versionNotSupported
    case connectionDropped
    case connectionFailed
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
        default:
            return .connectionFailed
        }
    }
}
