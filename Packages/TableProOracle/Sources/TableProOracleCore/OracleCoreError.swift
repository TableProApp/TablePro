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
    case transactionLost
    case authVerifierUnsupported(flag: String)
    case authVersionNotSupported
    case authConnectionDropped(phase: String?)
    case loginHandshakeStalled(phase: String?)
    case nativeEncryptionFailed(detail: String)
    case nativeEncryptionRequired
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
        case .transactionLost:
            return String(localized: "The connection was lost while a transaction was open. Check which of its changes were saved before running them again.")
        case .authVerifierUnsupported:
            return String(localized: "This account uses a password verifier the database driver does not support.")
        case .authVersionNotSupported:
            return String(localized: "This Oracle server is older than release 11.1, which the database driver does not support.")
        case .authConnectionDropped:
            return String(localized: "The Oracle server closed the connection during the login handshake.")
        case .loginHandshakeStalled(let phase):
            guard let phase else {
                return String(localized: "The Oracle server accepted the connection but stopped answering during the login.")
            }
            return String(
                format: String(localized: "The Oracle server stopped answering during the %@ step of the login."),
                Self.handshakePhaseName(phase)
            )
        case .nativeEncryptionRequired:
            return String(localized: """
                This Oracle server requires Native Network Encryption but did not offer it on this \
                connection. Ask the DBA to enable it, or use TLS instead by setting an SSL mode.
                """)
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

    /// The driver names the handshake step in its own vocabulary. These are the names
    /// a user can act on, and an unrecognized one falls back to the raw label rather
    /// than losing the only clue the dialog has.
    static func handshakePhaseName(_ phase: String) -> String {
        switch phase {
        case "connect": return String(localized: "connect")
        case "oobCheck": return String(localized: "out-of-band check")
        case "advancedNegotiation": return String(localized: "network encryption")
        case "protocolNegotiation": return String(localized: "protocol negotiation")
        case "dataTypeNegotiation": return String(localized: "data type negotiation")
        case "preAuthentication", "authentication": return String(localized: "sign in")
        case "tlsRenegotiation": return String(localized: "TLS renegotiation")
        default: return phase
        }
    }

    private static func certificateUnavailableFormat(for field: OracleCertificateField) -> String {
        switch field {
        case .certificateAuthority:
            return String(localized: """
                This connection's CA certificate is not readable on this device (%@). Certificate files do not \
                sync between devices, so add the certificate here or lower the SSL mode to Required.
                """)
        case .clientCertificate:
            return String(localized: """
                This connection's client certificate is not readable on this device (%@). Certificate files do \
                not sync between devices, so add the certificate here before connecting.
                """)
        case .clientKey:
            return String(localized: """
                This connection's client key is not readable on this device (%@). Key files do not sync between \
                devices, so add the key here before connecting.
                """)
        }
    }
}
