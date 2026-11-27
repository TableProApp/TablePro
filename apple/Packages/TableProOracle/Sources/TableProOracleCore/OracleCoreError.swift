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

public enum OracleRedirectFailure: Sendable, Equatable {
    case throughTunnel
    case unreadable
    case needsTLS
    case tooManyRedirects
    case unreachable(detail: String?)
    case refused(detail: String)
}

public enum OracleCoreError: LocalizedError, Sendable, Equatable {
    case notConnected
    case connectionFailed(String)
    case queryFailed(String)
    case cancelled
    case connectionClosed
    case protocolError
    case loginTimedOut
    case connectTimedOut
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
    case certificateAuthorityRequired
    case verifyIdentityNeedsHostName(address: String)
    case listenerRedirectFailed(OracleRedirectFailure, target: String?)
    case connectionRefused

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
        case .connectionClosed:
            return String(localized: "The Oracle connection closed while the statement was running. Run it again.")
        case .protocolError:
            return String(localized: "The server sent an unexpected message and the connection was reset. Run the query again.")
        case .loginTimedOut:
            return String(localized: "Timed out during the Oracle login handshake. The server accepted the network connection but did not finish logging in.")
        case .connectTimedOut:
            return String(localized: "The Oracle connection did not finish setup within the configured connection timeout.")
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
        case .certificateAuthorityRequired:
            return String(localized: "Verify CA needs a CA certificate. Choose the CA certificate that signed the server's certificate.")
        case .listenerRedirectFailed(let failure, let target):
            return Self.redirectMessage(failure, target: target)
        case .connectionRefused:
            return String(localized: "The server refused the connection. Check the host and port, and that the Oracle listener is running.")
        case .verifyIdentityNeedsHostName(let address):
            return String(
                format: String(localized: """
                    Verify Identity through a tunnel checks the certificate against the server's host name, and %@ \
                    is an IP address. Enter the server's host name, or set SSL Mode to Verify CA.
                    """),
                address
            )
        }
    }

    private static func redirectMessage(_ failure: OracleRedirectFailure, target: String?) -> String {
        let unreadable = String(localized: "The Oracle listener redirected the connection to an address TablePro could not read.")
        guard let target else {
            if case .tooManyRedirects = failure {
                return String(localized: "The Oracle listeners redirected the connection too many times.")
            }
            return unreadable
        }
        switch failure {
        case .throughTunnel:
            return String(
                format: String(localized: """
                    The Oracle listener redirected the connection to %@, which the tunnel does not forward. Enter that \
                    host and port as this connection's host and port so the tunnel reaches them.
                    """),
                target
            )
        case .unreadable:
            return unreadable
        case .needsTLS:
            return String(
                format: String(localized: "The Oracle listener redirected the connection to %@, which expects TLS. Set an SSL mode for this connection."),
                target
            )
        case .tooManyRedirects:
            return String(
                format: String(localized: "The Oracle listeners redirected the connection too many times. The last address was %@."),
                target
            )
        case .refused(let detail):
            return String(
                format: String(localized: "The Oracle listener redirected the connection to %1$@, and the listener there refused it. %2$@"),
                target,
                detail
            )
        case .unreachable(let detail):
            guard let detail else {
                return String(
                    format: String(localized: "The Oracle listener redirected the connection to %@, which could not be reached."),
                    target
                )
            }
            return String(
                format: String(localized: "The Oracle listener redirected the connection to %1$@, which could not be reached (%2$@)."),
                target,
                detail
            )
        }
    }

    /// What a driver failure with no server message behind it says to the user. OracleNIO's own
    /// error description is a struct dump it documents as unfit to show, so the code's name is
    /// what carries across.
    public static let driverErrorFormat = String(localized: "The Oracle driver reported an error (%@).")

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
