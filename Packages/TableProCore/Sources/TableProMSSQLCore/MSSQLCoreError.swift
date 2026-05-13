import Foundation

public enum MSSQLCoreError: LocalizedError, Sendable {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case cancelled
    case tlsHandshakeFailed(String)

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
        case .tlsHandshakeFailed(let detail):
            return String(format: String(localized: "TLS handshake failed: %@"), detail)
        }
    }
}
