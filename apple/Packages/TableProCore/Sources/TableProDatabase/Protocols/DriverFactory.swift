import Foundation
import TableProModels

public protocol DriverFactory: Sendable {
    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver
    // `preTunnelHost` is the saved host when `connection.host` is a tunnel's loopback, else nil.
    func createDriver(
        for connection: DatabaseConnection,
        password: String?,
        preTunnelHost: String?
    ) throws -> any DatabaseDriver
    // Runs before the tunnel, on the connection as saved, so a sign-in failure comes before any SSH prompt.
    func resolvePassword(
        for connection: DatabaseConnection,
        stored: String?,
        secureStore: any SecureStore
    ) async throws -> String?
    func supportedTypes() -> [DatabaseType]
}
