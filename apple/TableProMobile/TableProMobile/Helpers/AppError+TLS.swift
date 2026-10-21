import Foundation
import TableProPluginKit

nonisolated extension ErrorClassifier {
    static func tlsFailure(_ error: SSLHandshakeError) -> AppError {
        let title: String
        let recovery: String
        switch error {
        case .serverRejectedPlaintext:
            title = String(localized: "Server Requires TLS")
            recovery = String(localized: "Set SSL Mode to Preferred or Required.")
        case .serverRequiresPlaintext:
            title = String(localized: "Server Has No TLS")
            recovery = String(localized: "Turn on TLS on the server, or set SSL Mode to Preferred to connect without it.")
        case .hostnameMismatch:
            title = String(localized: "Certificate Name Mismatch")
            recovery = String(localized: "Check the host name, or set SSL Mode to Verify CA to skip the name check.")
        case .untrustedCertificate:
            title = String(localized: "Certificate Not Trusted")
            recovery = String(localized: "Add the CA certificate that signed the server's certificate, or set SSL Mode to Required.")
        default:
            title = String(localized: "TLS Handshake Failed")
            recovery = String(localized: "Check the server's TLS settings and this connection's SSL Mode.")
        }
        return AppError(
            category: .config,
            title: title,
            message: SSLHandshakeError.formatted(error),
            recovery: recovery,
            underlying: error,
            opensEditor: true
        )
    }
}
