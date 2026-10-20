import Foundation

public enum ConnectionError: Error, LocalizedError, Equatable {
    case driverNotFound(String)
    case notConnected
    case sshNotSupported
    case localSocketNotSupported
    case previousSessionStillClosing

    public var errorDescription: String? {
        switch self {
        case .driverNotFound(let type):
            return String(format: String(localized: "TablePro on iPhone and iPad can't open %@ connections."), type)
        case .notConnected:
            return String(localized: "Not connected to database")
        case .sshNotSupported:
            return String(localized: "SSH tunneling is not available on this platform")
        case .localSocketNotSupported:
            return String(localized: "This connection uses a socket on a Mac and cannot be opened on iPhone or iPad.")
        case .previousSessionStillClosing:
            return String(localized: "The previous session is still closing")
        }
    }
}
