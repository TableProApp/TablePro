import Foundation

public enum ConnectionError: Error, LocalizedError, Equatable {
    case driverNotFound(String)
    case notConnected
    case sshNotSupported
    case previousSessionStillClosing(String)

    public var errorDescription: String? {
        switch self {
        case .driverNotFound(let type):
            return "No driver available for database type: \(type)"
        case .notConnected:
            return "Not connected to database"
        case .sshNotSupported:
            return "SSH tunneling is not available on this platform"
        case .previousSessionStillClosing(let name):
            return String(
                format: String(localized: "%@ is still closing its previous session. Try again in a moment."),
                name
            )
        }
    }
}
