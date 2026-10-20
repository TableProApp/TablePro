import Foundation
import TableProModels

public protocol DriverFactory: Sendable {
    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver
    func supportedTypes() -> [DatabaseType]
    func refusal(for connection: DatabaseConnection) -> ConnectionError?
}

public extension DriverFactory {
    func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        supportedTypes().contains(connection.type) ? nil : .driverNotFound(connection.type.rawValue)
    }
}
