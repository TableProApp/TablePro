import Foundation

public enum LibPQSSLClassifier {
    public static func classifySSLError(_ message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("no pg_hba.conf entry") && lower.contains("no encryption") {
            return .serverRejectedPlaintext(serverMessage: message)
        }
        if lower.contains("no pg_hba.conf entry") && lower.contains("ssl") {
            return .serverRequiresPlaintext(serverMessage: message)
        }
        if lower.contains("server does not support ssl") || lower.contains("ssl is not enabled on the server") {
            return .serverRequiresPlaintext(serverMessage: message)
        }
        if lower.contains("certificate verify failed") || lower.contains("self-signed certificate") || lower.contains("unable to get local issuer certificate") {
            return .untrustedCertificate(serverMessage: message)
        }
        if lower.contains("server certificate") && lower.contains("does not match host name") {
            return .hostnameMismatch(serverMessage: message)
        }
        if lower.contains("certificate required") || lower.contains("connection requires a valid client certificate") {
            return .clientCertRequired(serverMessage: message)
        }
        if lower.contains("ssl error") || lower.contains("tls handshake") || lower.contains("ssl handshake") {
            return .cipherMismatch(serverMessage: message)
        }
        return nil
    }
}
