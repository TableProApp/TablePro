import Foundation

public enum MariaDBSSLClassifier {
    public static let sslOnlyErrorCodes: Set<UInt32> = [2_026, 2_012, 1_043]

    public static func classifySSLError(code: UInt32, message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("insecure transport") || lower.contains("require_secure_transport") {
            return .serverRejectedPlaintext(serverMessage: message)
        }
        if sslOnlyErrorCodes.contains(code) {
            // Connector/C's own wording, from my_auth.c and ma_tls.c.
            if lower.contains("server does not support it") {
                return .serverRequiresPlaintext(serverMessage: message)
            }
            if lower.contains("hostname verification failed") {
                return .hostnameMismatch(serverMessage: message)
            }
            if lower.contains("certificate") {
                return .untrustedCertificate(serverMessage: message)
            }
            return .cipherMismatch(serverMessage: message)
        }
        return nil
    }
}
