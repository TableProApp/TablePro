import Foundation
import TableProDatabase
import TableProModels

final class StubDriverFactory: DriverFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var driversByType: [String: any DatabaseDriver] = [:]
    private var queuedDrivers: [any DatabaseDriver] = []
    private var dialedConnections: [DatabaseConnection] = []

    var drivers: [String: any DatabaseDriver] {
        get { lock.withLock { driversByType } }
        set { lock.withLock { driversByType = newValue } }
    }

    var dialed: [DatabaseConnection] {
        lock.withLock { dialedConnections }
    }

    // Handed out one per dial, ahead of `drivers`, so each redial gets a driver of its own.
    func queue(_ driver: any DatabaseDriver) {
        lock.withLock { queuedDrivers.append(driver) }
    }

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        try lock.withLock {
            dialedConnections.append(connection)
            if !queuedDrivers.isEmpty {
                return queuedDrivers.removeFirst()
            }
            guard let driver = driversByType[connection.type.rawValue] else {
                throw ConnectionError.driverNotFound(connection.type.rawValue)
            }
            return driver
        }
    }

    func supportedTypes() -> [DatabaseType] { drivers.keys.map(DatabaseType.init(rawValue:)) }

    // A queued driver answers a dial of any type.
    func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        lock.withLock {
            queuedDrivers.isEmpty && driversByType[connection.type.rawValue] == nil
                ? ConnectionError.driverNotFound(connection.type.rawValue)
                : nil
        }
    }
}
