import Foundation

public enum RedisSSLClassifier {
    public static func classifySSLError(_ message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("certificate verify failed") || lower.contains("unable to get local issuer") {
            return .untrustedCertificate(serverMessage: message)
        }
        if lower.contains("hostname") {
            return .hostnameMismatch(serverMessage: message)
        }
        if lower.contains("sslv3") || lower.contains("unsupported protocol") || lower.contains("no shared cipher") {
            return .cipherMismatch(serverMessage: message)
        }
        if lower.contains("ssl handshake failed") || lower.contains("tlsv1") {
            return .cipherMismatch(serverMessage: message)
        }
        if lower.contains("client certificate") {
            return .clientCertRequired(serverMessage: message)
        }
        return nil
    }
}
