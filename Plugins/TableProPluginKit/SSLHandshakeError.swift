import Foundation

public enum SSLHandshakeError: Error, LocalizedError, Sendable {
    case serverRejectedPlaintext(serverMessage: String)
    case serverRequiresPlaintext(serverMessage: String)
    case untrustedCertificate(serverMessage: String)
    case hostnameMismatch(serverMessage: String)
    case clientCertRequired(serverMessage: String)
    case cipherMismatch(serverMessage: String)
    case unknown(serverMessage: String)
    case clientKeyPassphraseRequired(serverMessage: String)
    case clientKeyPassphraseIncorrect(serverMessage: String)
    case clientKeyInvalid(serverMessage: String)

    public var serverMessage: String {
        switch self {
        case .serverRejectedPlaintext(let msg),
             .serverRequiresPlaintext(let msg),
             .untrustedCertificate(let msg),
             .hostnameMismatch(let msg),
             .clientCertRequired(let msg),
             .clientKeyPassphraseRequired(let msg),
             .clientKeyPassphraseIncorrect(let msg),
             .clientKeyInvalid(let msg),
             .cipherMismatch(let msg),
             .unknown(let msg):
            return msg
        }
    }

    public var errorDescription: String? {
        switch self {
        case .serverRejectedPlaintext:
            return String(localized: "The server requires an encrypted connection but TablePro is configured to connect in plain text.")
        case .serverRequiresPlaintext:
            return String(localized: "The server does not accept encrypted connections but TablePro is configured to require TLS.")
        case .untrustedCertificate:
            return String(localized: "The server's TLS certificate could not be verified against any trusted root.")
        case .hostnameMismatch:
            return String(localized: "The server's TLS certificate does not match the hostname being connected to.")
        case .clientCertRequired:
            return String(localized: "The server requires a client certificate for TLS mutual authentication.")
        case .clientKeyPassphraseRequired:
            return String(localized: "The client private key is encrypted and needs a passphrase.")
        case .clientKeyPassphraseIncorrect:
            return String(localized: "The passphrase for the client private key is incorrect.")
        case .clientKeyInvalid:
            return String(localized: "The client private key could not be read. It may be malformed or in an unsupported format.")
        case .cipherMismatch:
            return String(localized: "The server and TablePro could not agree on a TLS cipher or protocol version.")
        case .unknown:
            return String(localized: "TLS handshake failed.")
        }
    }

    public static func formatted(_ error: Error) -> String {
        guard let sslError = error as? SSLHandshakeError else {
            return error.localizedDescription
        }
        var parts: [String] = []
        if let description = sslError.errorDescription {
            parts.append(description)
        }
        if let suggestion = sslError.recoverySuggestion {
            parts.append(suggestion)
        }
        parts.append(String(format: String(localized: "Server response: %@"), sanitize(sslError.serverMessage)))
        return parts.joined(separator: "\n\n")
    }

    static func sanitize(_ message: String) -> String {
        var redacted = message
        let userInfo = try? NSRegularExpression(pattern: "://[^/@\\s]+:[^/@\\s]+@", options: [])
        if let userInfo {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = userInfo.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "://[redacted]@")
        }
        let kvPattern = try? NSRegularExpression(pattern: "(password|passwd|pwd)\\s*=\\s*\\S+", options: [.caseInsensitive])
        if let kvPattern {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = kvPattern.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "$1=[redacted]")
        }
        return redacted
    }

    public var recoverySuggestion: String? {
        switch self {
        case .serverRejectedPlaintext:
            return String(localized: "Open the connection editor, switch to the SSL tab, and set Mode to Required (or stricter).")
        case .serverRequiresPlaintext:
            return String(localized: "Open the connection editor, switch to the SSL tab, and set Mode to Disabled.")
        case .untrustedCertificate:
            return String(localized: """
                Switch SSL Mode to Verify CA and provide the server's CA certificate path. \
                Required mode also connects, but does not validate the certificate chain.
                """)
        case .hostnameMismatch:
            return String(localized: "Switch SSL Mode to Verify CA (validates the CA chain but skips hostname check), or update the host field to match the certificate.")
        case .clientCertRequired:
            return String(localized: "Provide the client certificate and key paths in the SSL tab.")
        case .clientKeyPassphraseRequired:
            return String(localized: "Open the connection editor, switch to the SSL tab, and enter the Key Passphrase.")
        case .clientKeyPassphraseIncorrect:
            return String(localized: "Open the connection editor, switch to the SSL tab, and correct the Key Passphrase.")
        case .clientKeyInvalid:
            return String(localized: "Check that the Client Key path points to a valid PEM private key.")
        case .cipherMismatch:
            return String(localized: "Update the server's TLS configuration or use a newer database server version that supports modern ciphers.")
        case .unknown:
            return nil
        }
    }
}
