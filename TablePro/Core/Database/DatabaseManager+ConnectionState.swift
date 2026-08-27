import Foundation

enum ConnectionState {
    case live(DatabaseDriver, ConnectionSession)
    case stored(DatabaseConnection)
    case unknown
}

extension DatabaseManager {
    @MainActor
    func connectionState(_ id: UUID) -> ConnectionState {
        /// A driver a reconnect has given up on is installed but not live, and handing it out here
        /// is how an external client keeps routing work to a socket the server closed.
        if let session = activeSessions[id], let driver = session.driver, session.liveness == .live {
            return .live(driver, session)
        }
        if let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == id }) {
            return .stored(connection)
        }
        return .unknown
    }
}
