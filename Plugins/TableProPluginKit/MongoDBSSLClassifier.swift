import Foundation

public enum MongoDBSSLClassifier {
    public static func classifySSLError(_ message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("certificate verify failed") || lower.contains("ssl certificate") {
            return .untrustedCertificate(serverMessage: message)
        }
        if lower.contains("hostname") && lower.contains("verification") {
            return .hostnameMismatch(serverMessage: message)
        }
        if lower.contains("tls required") || lower.contains("ssl required") {
            return .serverRejectedPlaintext(serverMessage: message)
        }
        if lower.contains("client certificate required") || lower.contains("peer did not return a certificate") {
            return .clientCertRequired(serverMessage: message)
        }
        if isCipherOrProtocolMismatch(lower) {
            return .cipherMismatch(serverMessage: message)
        }
        if lower.contains("ssl handshake failed") || lower.contains("tls handshake failed") {
            return .unknown(serverMessage: message)
        }
        return nil
    }

    public static func isCipherOrProtocolMismatch(_ lower: String) -> Bool {
        let signatures = [
            "no shared cipher",
            "sslv3 alert handshake failure",
            "wrong version number",
            "unsupported protocol",
            "no protocols available",
            "alert protocol version",
            "protocol version",
        ]
        return signatures.contains { lower.contains($0) }
    }
}
