import Foundation
import TableProModels

public extension DriverFactory {
    func createDriver(
        for connection: DatabaseConnection,
        password: String?,
        preTunnelHost: String?
    ) throws -> any DatabaseDriver {
        try createDriver(for: connection, password: password)
    }

    func createDriver(
        for connection: DatabaseConnection,
        password: String?,
        preTunnelHost: String?,
        refreshPassword: (@Sendable () async throws -> String?)?
    ) throws -> any DatabaseDriver {
        try createDriver(for: connection, password: password, preTunnelHost: preTunnelHost)
    }

    func resolvePassword(
        for connection: DatabaseConnection,
        stored: String?,
        secureStore: any SecureStore
    ) async throws -> String? {
        stored
    }
}
