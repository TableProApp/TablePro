import Foundation

public enum MSSQLTLSFailureKind: Sendable {
    case serverRejectedPlaintext
    case serverRequiresPlaintext
    case untrustedCertificate
    case hostnameMismatch
    case clientCertRequired
    case cipherMismatch
}

public enum MSSQLKerberosFailureKind: Sendable, Equatable {
    case noCredential
    case principalUnknown
    case wrongPassword
    case spnNotFound
    case clockSkew
    case realmNotResolved
    case ticketExpired
}

public enum MSSQLCoreError: LocalizedError, Sendable {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case cancelled
    case tlsHandshakeFailed(kind: MSSQLTLSFailureKind, serverMessage: String)
    case kerberosAuthFailed(kind: MSSQLKerberosFailureKind, serverMessage: String)
    case connectionTimedOut(isKerberos: Bool)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail):
            return String(format: String(localized: "Connection failed: %@"), detail)
        case .notConnected:
            return String(localized: "Not connected to SQL Server")
        case .queryFailed(let detail):
            return String(format: String(localized: "Query failed: %@"), detail)
        case .cancelled:
            return String(localized: "Query was cancelled")
        case .tlsHandshakeFailed(_, let serverMessage):
            return String(format: String(localized: "TLS handshake failed: %@"), serverMessage)
        case .kerberosAuthFailed(_, let serverMessage):
            return String(format: String(localized: "Kerberos authentication failed: %@"), serverMessage)
        case .connectionTimedOut(let isKerberos):
            if isKerberos {
                return String(localized: "Timed out completing Kerberos authentication. The Kerberos KDC (domain controller) may be unreachable, the server's SPN may be missing, or this Mac's clock may be off. Check your network to the domain, or use SQL Server Authentication.")
            }
            return String(localized: "Timed out connecting to the server. Check the host, port, and that the server is reachable and accepting connections.")
        }
    }
}
