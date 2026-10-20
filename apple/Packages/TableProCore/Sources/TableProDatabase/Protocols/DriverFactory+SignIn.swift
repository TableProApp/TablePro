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

    func resolvePassword(
        for connection: DatabaseConnection,
        stored: String?,
        secureStore: any SecureStore
    ) async throws -> String? {
        stored
    }
}
