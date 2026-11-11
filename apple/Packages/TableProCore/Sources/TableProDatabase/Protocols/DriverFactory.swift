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
    // `refreshPassword` resolves the password again for the connection as saved, whose endpoint a tunnel hides from
    // `connection`. A driver that signs in a second time later, such as to stop a statement, calls it once a minted
    // token may have expired.
    func createDriver(
        for connection: DatabaseConnection,
        password: String?,
        preTunnelHost: String?,
        refreshPassword: (@Sendable () async throws -> String?)?
    ) throws -> any DatabaseDriver
    // Runs first, on the connection as saved. The connect mints for, tunnels to and dials what it returns, which can
    // name another host, such as the RDS endpoint a CNAME stands for. It is never saved.
    func resolvingEndpointAlias(for connection: DatabaseConnection) async throws -> DatabaseConnection
    // Runs before the tunnel, so a sign-in failure comes before any SSH prompt.
    func resolvePassword(
        for connection: DatabaseConnection,
        stored: String?,
        secureStore: any SecureStore
    ) async throws -> String?
    func supportedTypes() -> [DatabaseType]
    func refusal(for connection: DatabaseConnection) -> ConnectionError?
    // Whether a second connection reaches the same database as the session, for catalog reads.
    func opensCatalogConnections(for connection: DatabaseConnection) -> Bool
    // Runs once on a catalog connection after it connects, never on the user's session.
    func prepareCatalogDriver(_ driver: any DatabaseDriver, for connection: DatabaseConnection) async throws
    // Whether the connection's SSH tunnel is dialed. A record can carry a tunnel its engine has no use for, such as
    // one kept from the type it had before, and dialing it would fail the connect before the driver is made.
    func dialsSSHTunnel(for connection: DatabaseConnection) -> Bool
}

public extension DriverFactory {
    func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        supportedTypes().contains(connection.type) ? nil : .driverNotFound(connection.type.rawValue)
    }

    func opensCatalogConnections(for connection: DatabaseConnection) -> Bool {
        false
    }

    func prepareCatalogDriver(_ driver: any DatabaseDriver, for connection: DatabaseConnection) async throws {}

    func dialsSSHTunnel(for connection: DatabaseConnection) -> Bool {
        connection.sshEnabled
    }

    func resolvingEndpointAlias(for connection: DatabaseConnection) async throws -> DatabaseConnection {
        connection
    }
}
