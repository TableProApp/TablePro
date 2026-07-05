import Foundation

public enum MSSQLTLSClassifier {
    public static func classifySSLError(_ message: String) -> MSSQLTLSFailureKind? {
        let lower = message.lowercased()
        if lower.contains("encryption is required") || lower.contains("server requires encryption") {
            return .serverRejectedPlaintext
        }
        if lower.contains("encryption not supported") || lower.contains("server does not support encryption") {
            return .serverRequiresPlaintext
        }
        if lower.contains("certificate verify failed") || lower.contains("certificate is not trusted") {
            return .untrustedCertificate
        }
        if lower.contains("does not match host") {
            return .hostnameMismatch
        }
        if lower.contains("ssl handshake") || lower.contains("tls handshake") || lower.contains("openssl error") {
            return .cipherMismatch
        }
        return nil
    }
}
