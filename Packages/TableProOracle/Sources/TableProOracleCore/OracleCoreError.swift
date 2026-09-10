import Foundation

public enum OracleTLSFailureKind: Sendable, Equatable {
    case clientCertRequired
    case cipherMismatch
    case untrustedCertificate
    case unknown
}

public enum OracleCertificateField: Sendable, Equatable {
    case certificateAuthority
    case clientCertificate
    case clientKey
}

public enum OracleCoreError: LocalizedError, Sendable, Equatable {
    case notConnected
    case connectionFailed(String)
    case queryFailed(String)
    case cancelled
    case protocolError
    case loginTimedOut
    case queryTimedOut
    case authVerifierUnsupported(flag: String)
    case authVersionNotSupported
    case authConnectionDropped(phase: String?)
    case nativeEncryptionFailed(detail: String)
    case tlsHandshakeFailed(kind: OracleTLSFailureKind, serverMessage: String)
    case certificateUnavailable(field: OracleCertificateField, path: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to database")
        case .connectionFailed(let detail):
            return detail.isEmpty ? String(localized: "Failed to establish connection") : detail
        case .queryFailed(let detail):
            return detail.isEmpty ? String(localized: "Query execution failed") : detail
        case .cancelled:
            return String(localized: "Query was cancelled")
        case .protocolError:
            return String(localized: "The server sent an unexpected message and the connection was reset. Run the query again.")
        case .loginTimedOut:
            return String(localized: "Timed out during the Oracle login handshake. The server accepted the network connection but did not finish logging in.")
        case .queryTimedOut:
            return String(localized: "The query did not finish within the configured timeout, so the connection was reset. Run the query again.")
        case .authVerifierUnsupported:
            return String(localized: "This account uses a password verifier the database driver does not support.")
        case .authVersionNotSupported:
            return String(localized: "This Oracle server is older than release 11.1, which the database driver does not support.")
        case .authConnectionDropped:
            return String(localized: "The Oracle server closed the connection during the login handshake.")
        case .nativeEncryptionFailed(let detail):
            let base = String(localized: """
                Could not complete Oracle native network encryption with this server. It may \
                require an encryption or checksum algorithm the driver does not support.
                """)
            return detail.isEmpty ? base : String(format: String(localized: "%1$@ (%2$@)"), base, detail)
        case .tlsHandshakeFailed(_, let serverMessage):
            return String(format: String(localized: "TLS handshake failed: %@"), serverMessage)
        case .certificateUnavailable(let field, let path):
            return String(format: Self.certificateUnavailableFormat(for: field), path)
        }
    }

    private static func certificateUnavailableFormat(for field: OracleCertificateField) -> String {
        switch field {
        case .certificateAuthority:
            return String(localized: "This connection's CA certificate is not readable on this device (%@). Certificate files do not sync between devices, so add the certificate here or lower the SSL mode to Required.")
        case .clientCertificate:
            return String(localized: "This connection's client certificate is not readable on this device (%@). Certificate files do not sync between devices, so add the certificate here before connecting.")
        case .clientKey:
            return String(localized: "This connection's client key is not readable on this device (%@). Key files do not sync between devices, so add the key here before connecting.")
        }
    }
}
