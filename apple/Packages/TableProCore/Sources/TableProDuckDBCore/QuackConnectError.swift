import Foundation

public enum QuackConnectError: Error, LocalizedError, Equatable, Sendable {
    case missingHost
    case missingToken
    case invalidPort
    case missingFingerprint
    case invalidFingerprint
    case tunneledVerifyIdentity
    case tunneledAutomatic(server: String)
    case caCertificateUnreadable(path: String, reason: String)
    case caCertificateNotPEM(path: String)
    case trustBundleUnwritable(reason: String)
    case extensionNotInstalled(name: String, detail: String)
    case extensionNotLoaded(name: String, detail: String)
    case certificateNotTrusted(detail: String)
    case serverExpectsHTTPS(detail: String, tunneled: Bool)
    case serverExpectsPlainHTTP(detail: String)
    case fingerprintMismatch(detail: String)
    case caCertificateRejected(detail: String)

    public var errorDescription: String? {
        switch self {
        case .missingHost:
            return String(localized: "Host is required for a remote DuckDB connection")
        case .missingToken:
            return String(localized: "Token is required. Enter the token the server was started with, from quack_serve.")
        case .invalidPort:
            return String(localized: "Port must be a number between 1 and 65535")
        case .missingFingerprint:
            return String(localized: """
                Verify Fingerprint needs the server's Certificate Fingerprint. Run quack_server_list() on the \
                server to read it.
                """)
        case .invalidFingerprint:
            return String(localized: """
                The Certificate Fingerprint is not a SHA-256 fingerprint. Enter the 64 hex digits that \
                quack_server_list() shows on the server, with or without colons.
                """)
        case .tunneledVerifyIdentity:
            return String(localized: """
                Verify Identity does not work through a tunnel. DuckDB checks the certificate against \
                127.0.0.1 there, not against the server's name. Set SSL Mode to Verify Fingerprint, or to \
                Required (skip verify).
                """)
        case .tunneledAutomatic(let server):
            return String(
                format: String(localized: """
                    Automatic does not work through a tunnel to %@. DuckDB would use HTTPS and check the \
                    certificate against 127.0.0.1, not against the server's name. Set SSL Mode to Verify \
                    Fingerprint or Required (skip verify), or to Disabled if the server serves plain HTTP.
                    """),
                server
            )
        case .caCertificateUnreadable(let path, let reason):
            return String(format: String(localized: "TablePro could not read the CA Certificate at %@: %@"), path, reason)
        case .caCertificateNotPEM(let path):
            return String(
                format: String(localized: """
                    The CA Certificate at %@ is not a PEM certificate. DuckDB reads PEM files only. Convert a DER \
                    file with: openssl x509 -inform der -in ca.der -out ca.pem
                    """),
                path
            )
        case .trustBundleUnwritable(let reason):
            return String(format: String(localized: "TablePro could not write the CA bundle DuckDB reads: %@"), reason)
        case .extensionNotInstalled(let name, let detail):
            return Self.reported(
                String(
                    format: String(localized: """
                        DuckDB could not install its %@ extension. It downloads the extension from \
                        extensions.duckdb.org the first time it connects to a remote database.
                        """),
                    name
                ),
                detail: detail
            )
        case .extensionNotLoaded(let name, let detail):
            return Self.reported(
                String(format: String(localized: "DuckDB could not load its %@ extension."), name),
                detail: detail
            )
        case .certificateNotTrusted(let detail):
            return Self.reported(
                String(localized: """
                    DuckDB could not verify the server's certificate. Either no CA it trusts signed it, or it \
                    was not issued for this host name. DuckDB checks certificates against /etc/ssl/cert.pem and \
                    the CA Certificate, and does not read the macOS keychain, so a CA added in Keychain Access \
                    is not trusted.
                    """),
                String(localized: """
                    Set SSL Mode to Verify Identity and choose the CA that signed the certificate in CA \
                    Certificate, or set SSL Mode to Verify Fingerprint and enter the server's Certificate \
                    Fingerprint. Required (skip verify) also connects, but does not check the certificate.
                    """),
                detail: detail
            )
        case .serverExpectsHTTPS(let detail, let tunneled):
            return Self.reported(
                String(localized: "The server uses HTTPS, and this connection sent plain HTTP."),
                tunneled
                    ? String(localized: """
                        Set SSL Mode to Verify Fingerprint, or to Required (skip verify) to encrypt without \
                        checking the certificate.
                        """)
                    : String(localized: """
                        Set SSL Mode to Verify Identity, or to Verify Fingerprint for a server with a \
                        self-signed certificate.
                        """),
                detail: detail
            )
        case .serverExpectsPlainHTTP(let detail):
            return Self.reported(
                String(localized: "The server did not answer the TLS handshake. If it serves plain HTTP, set SSL Mode to Disabled."),
                detail: detail
            )
        case .fingerprintMismatch(let detail):
            return Self.reported(
                String(localized: """
                    The server's certificate does not match the Certificate Fingerprint. If the server has a new \
                    certificate, copy its fingerprint again from quack_server_list() on the server.
                    """),
                detail: detail
            )
        case .caCertificateRejected(let detail):
            return Self.reported(
                String(localized: "DuckDB could not read the CA Certificate. It reads PEM files only."),
                detail: detail
            )
        }
    }

    /// DuckDB's own text stays at the end: it carries the URL that was dialed, which tells a tunnel's
    /// loopback from the server.
    private static func reported(_ parts: String..., detail: String) -> String {
        (parts + [String(format: String(localized: "DuckDB reported: %@"), detail)]).joined(separator: "\n\n")
    }
}

/// Maps the texts quack and httpfs's curl give for a TLS mismatch to messages that name the field to
/// change. The texts were measured on DuckDB v2.0.0 with quack f96420ed and httpfs 77392a7; any other
/// failure keeps DuckDB's own text.
public enum QuackConnectErrorClassifier {
    public static func classify(_ error: any Error, tunneled: Bool) -> QuackConnectError? {
        if let error = error as? QuackConnectError { return error }
        return classify(message: error.localizedDescription, tunneled: tunneled)
    }

    public static func classify(message: String, tunneled: Bool) -> QuackConnectError? {
        // The pinned client's own text, from a server whose certificate is not the pinned one.
        if message.contains("does not match the pinned ssl_fingerprint") {
            return .fingerprintMismatch(detail: message)
        }
        // curl gives one text for a CA it does not trust and for a certificate issued to another name,
        // so one message covers both.
        if message.contains("SSL peer certificate or SSH remote key was not OK") {
            return .certificateNotTrusted(detail: message)
        }
        if message.contains("Problem with the SSL CA cert") {
            return .caCertificateRejected(detail: message)
        }
        // Plain HTTP to a server that speaks TLS.
        if message.contains("Unsupported protocol") {
            return .serverExpectsHTTPS(detail: message, tunneled: tunneled)
        }
        // HTTPS to a plain HTTP server: curl's text, then the pinned client's.
        if message.contains("SSL connect error") || message.contains("SSL connection failed") {
            return .serverExpectsPlainHTTP(detail: message)
        }
        return nil
    }
}
