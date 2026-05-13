import Foundation

enum ConnectionState {
    case live(DatabaseDriver, ConnectionSession)
    case stored(DatabaseConnection)
    case unknown
}

extension DatabaseManager {
    @MainActor
    func connectionState(_ id: UUID) -> ConnectionState {
        if let session = activeSessions[id], let driver = session.driver {
            return .live(driver, session)
        }
        if let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == id }) {
            return .stored(connection)
        }
        return .unknown
    }
}
