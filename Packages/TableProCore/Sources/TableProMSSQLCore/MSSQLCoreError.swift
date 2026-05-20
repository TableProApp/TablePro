import Foundation

public enum MSSQLTLSFailureKind: Sendable {
    case serverRejectedPlaintext
    case serverRequiresPlaintext
    case untrustedCertificate
    case hostnameMismatch
    case clientCertRequired
    case cipherMismatch
}

public enum MSSQLCoreError: LocalizedError, Sendable {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case cancelled
    case tlsHandshakeFailed(kind: MSSQLTLSFailureKind, serverMessage: String)

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
        }
    }
}
