import Foundation
import TableProModels

public protocol DriverFactory: Sendable {
    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver
    func supportedTypes() -> [DatabaseType]
    func refusal(for connection: DatabaseConnection) -> ConnectionError?
    // Whether a second connection reaches the same database as the session, for catalog reads.
    func opensCatalogConnections(for connection: DatabaseConnection) -> Bool
    // Runs once on a catalog connection after it connects, never on the user's session.
    func prepareCatalogDriver(_ driver: any DatabaseDriver, for connection: DatabaseConnection) async throws
}

public extension DriverFactory {
    func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        supportedTypes().contains(connection.type) ? nil : .driverNotFound(connection.type.rawValue)
    }

    func opensCatalogConnections(for connection: DatabaseConnection) -> Bool {
        false
    }

    func prepareCatalogDriver(_ driver: any DatabaseDriver, for connection: DatabaseConnection) async throws {}
}
