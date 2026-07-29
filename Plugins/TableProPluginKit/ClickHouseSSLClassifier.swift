import Foundation

public enum ClickHouseSSLClassifier {
    public static func classifySSLError(_ error: Error) -> SSLHandshakeError? {
        let urlError = error as? URLError ?? (error as NSError).underlyingErrors.compactMap { $0 as? URLError }.first
        if let urlError {
            switch urlError.code {
            case .serverCertificateUntrusted, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate:
                return .untrustedCertificate(serverMessage: urlError.localizedDescription)
            case .clientCertificateRequired, .clientCertificateRejected:
                return .clientCertRequired(serverMessage: urlError.localizedDescription)
            case .secureConnectionFailed:
                return .cipherMismatch(serverMessage: urlError.localizedDescription)
            default:
                break
            }
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("certificate") && (message.contains("untrusted") || message.contains("verify failed")) {
            return .untrustedCertificate(serverMessage: error.localizedDescription)
        }
        if message.contains("hostname") {
            return .hostnameMismatch(serverMessage: error.localizedDescription)
        }
        return nil
    }
}
