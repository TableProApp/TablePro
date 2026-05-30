import Foundation
import TableProPluginKit

enum LibPQClassifier {
    static func classifySSLError(_ message: String) -> SSLHandshakeError? {
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

enum MariaDBClassifier {
    static let sslOnlyErrorCodes: Set<UInt32> = [2_026, 2_012, 1_043]

    static func classifySSLError(code: UInt32, message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("insecure transport") || lower.contains("require_secure_transport") {
            return .serverRejectedPlaintext(serverMessage: message)
        }
        if sslOnlyErrorCodes.contains(code) {
            if lower.contains("certificate") {
                return .untrustedCertificate(serverMessage: message)
            }
            return .cipherMismatch(serverMessage: message)
        }
        return nil
    }
}

enum FreeTDSClassifier {
    static func classifySSLError(_ message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("encryption is required") || lower.contains("server requires encryption") {
            return .serverRejectedPlaintext(serverMessage: message)
        }
        if lower.contains("encryption not supported") || lower.contains("server does not support encryption") {
            return .serverRequiresPlaintext(serverMessage: message)
        }
        if lower.contains("certificate verify failed") || lower.contains("certificate is not trusted") {
            return .untrustedCertificate(serverMessage: message)
        }
        if lower.contains("does not match host") {
            return .hostnameMismatch(serverMessage: message)
        }
        if lower.contains("ssl handshake") || lower.contains("tls handshake") || lower.contains("openssl error") {
            return .cipherMismatch(serverMessage: message)
        }
        return nil
    }
}

enum MongoDBClassifier {
    static func classifySSLError(_ message: String) -> SSLHandshakeError? {
        let lower = message.lowercased()
        if lower.contains("ssl handshake failed") || lower.contains("tls handshake failed") {
            return .cipherMismatch(serverMessage: message)
        }
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
        return nil
    }
}

enum RedisClassifier {
    static func classifySSLError(_ message: String) -> SSLHandshakeError? {
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

enum OracleClassifier {
    static func classifySSLError(_ message: String) -> SSLHandshakeError? {
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

enum ClickHouseClassifier {
    static func classifySSLError(_ error: Error) -> SSLHandshakeError? {
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

enum CassandraClassifier {
    static func isEncryptedPrivateKey(_ pem: String) -> Bool {
        pem.contains("ENCRYPTED PRIVATE KEY") || (pem.contains("Proc-Type:") && pem.contains("ENCRYPTED"))
    }

    static func privateKeyLoadError(keyPEM: String, hasPassphrase: Bool, keyPath: String) -> SSLHandshakeError {
        guard isEncryptedPrivateKey(keyPEM) else {
            return .clientKeyInvalid(serverMessage: "The client key at \(keyPath) is not a valid private key")
        }
        if hasPassphrase {
            return .clientKeyPassphraseIncorrect(serverMessage: "The passphrase for the client key at \(keyPath) is incorrect")
        }
        return .clientKeyPassphraseRequired(serverMessage: "The client key at \(keyPath) is encrypted. Enter its passphrase.")
    }
}
