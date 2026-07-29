import Foundation

public enum OracleSSLClassifier {
    public static func classifySSLError(_ message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("ora-28759") || lower.contains("failure to open file") && lower.contains("wallet") {
            return .clientCertRequired(serverMessage: message)
        }
        if lower.contains("ora-29024") {
            return .cipherMismatch(serverMessage: message)
        }
        if lower.contains("ora-28860") {
            return .cipherMismatch(serverMessage: message)
        }
        if lower.contains("certificate") && (lower.contains("verify") || lower.contains("untrusted")) {
            return .untrustedCertificate(serverMessage: message)
        }
        return nil
    }
}
