import Foundation
@testable import TableProDatabase
@testable import TableProModels
import TableProTestSupport
import Testing

@Suite("ConnectionManager catalog connection", .timeLimit(.minutes(1)))
struct ConnectionManagerCatalogTests {
    private static let type = DatabaseType(rawValue: "mock")

    private func connection(ssh: Bool = false) -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Test",
            type: Self.type,
            host: "db.example.com",
            port: 5_432,
            database: "app"
        )
        if ssh {
            connection.sshEnabled = true
            connection.sshConfiguration = SSHConfiguration(host: "bastion.example.com", username: "deploy")
        }
        return connection
    }

    @Test("The catalog driver is a second driver dialed through the session's tunnel, on the asked database")
    func dialsThroughTheTunnel() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(),
            sshProvider: MockSSHProvider()
        )
        let connection = connection(ssh: true)
        let session = try await manager.connect(connection)

        let catalog = try #require(await manager.catalogDriver(for: connection.id, database: "sales"))

        #expect(catalog !== session.driver)
        let dialed = factory.dialed
        #expect(dialed.count == 2)
        #expect(dialed[1].host == "127.0.0.1")
        #expect(dialed[1].port == 33_306)
        #expect(dialed[1].database == "sales")
        #expect((catalog as? MockDatabaseDriver)?.isConnected == true)
    }

    @Test("The catalog driver takes the session's tunnel overrides: no TLS to a unix socket, the saved host to verify")
    func keepsTheSessionsTunnelOverrides() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(),
            sshProvider: MockSSHProvider()
        )
        var connection = connection(ssh: true)
        connection.sslEnabled = true
        connection.additionalFields[DatabaseConnection.sshForwardUnixSocketPathKey] = "/var/run/mysqld/mysqld.sock"
        _ = try await manager.connect(connection)

        _ = try #require(await manager.catalogDriver(for: connection.id, database: "app"))

        let dialed = factory.dialed
        #expect(dialed.count == 2)
        #expect(dialed[1].sslEnabled == dialed[0].sslEnabled)
        #expect(dialed[1].sslEnabled == false)
        #expect(dialed[1].additionalFields[DatabaseConnection.preTunnelHostKey] == "db.example.com")
    }

    @Test("A hold closes the catalog connection and opens none until released")
    func holdClosesAndBlocksTheCatalog() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)
        let first = try #require(await manager.catalogDriver(for: connection.id, database: "app") as? MockDatabaseDriver)

        await manager.holdCatalogConnections(for: connection.id)

        #expect(!first.isConnected)
        #expect(await manager.catalogDriver(for: connection.id, database: "app") == nil)
        manager.releaseCatalogConnections(for: connection.id)
        #expect(await manager.catalogDriver(for: connection.id, database: "app") != nil)
    }

    @Test("Readers share one catalog driver until the database changes, which closes the old one")
    func sharedUntilTheDatabaseChanges() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)

        async let first = manager.catalogDriver(for: connection.id, database: "app")
        async let second = manager.catalogDriver(for: connection.id, database: "app")
        let (one, two) = await (first, second)
        let shared = try #require(one as? MockDatabaseDriver)
        #expect(two === shared)

        let moved = try #require(await manager.catalogDriver(for: connection.id, database: "sales"))
        #expect(moved !== shared)
        try await waitUntil(timeout: .seconds(5)) { shared.disconnectCount == 1 }
        #expect(factory.dialed.count == 3)
    }

    @Test("The factory prepares the catalog driver, and never the session's")
    func preparedOnce() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        let session = try await manager.connect(connection)

        let catalog = try #require(await manager.catalogDriver(for: connection.id, database: "app"))
        _ = await manager.catalogDriver(for: connection.id, database: "app")

        #expect(factory.prepared.count == 1)
        #expect(factory.prepared.first === catalog)
        #expect(factory.prepared.first !== session.driver)
    }

    @Test("An engine that keeps one connection gets no catalog driver")
    func declinedByTheFactory() async throws {
        let factory = DialingDriverFactory(opensCatalogs: false)
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)

        #expect(await manager.catalogDriver(for: connection.id, database: "app") == nil)
        #expect(factory.dialed.count == 1)
    }

    @Test("No session, no catalog driver")
    func noSession() async {
        let manager = ConnectionManager(driverFactory: DialingDriverFactory(), secureStore: MockSecureStore())
        #expect(await manager.catalogDriver(for: UUID(), database: "app") == nil)
    }

    @Test("A failed open is tried again only after the retry delay")
    func failedOpenRetriesLater() async throws {
        let factory = DialingDriverFactory()
        let clock = SettableNow()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore(), now: { clock.date })
        let connection = connection()
        _ = try await manager.connect(connection)
        factory.failsConnect = true

        #expect(await manager.catalogDriver(for: connection.id, database: "app") == nil)
        clock.advance(by: ConnectionManager.catalogRetryDelay - 1)
        #expect(await manager.catalogDriver(for: connection.id, database: "app") == nil)
        #expect(factory.dialed.count == 2)

        factory.failsConnect = false
        clock.advance(by: 2)
        #expect(await manager.catalogDriver(for: connection.id, database: "app") != nil)
        #expect(factory.dialed.count == 3)
    }

    @Test("A connection idle past the limit is replaced by a fresh one")
    func idleConnectionIsReplaced() async throws {
        let factory = DialingDriverFactory()
        let clock = SettableNow()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore(), now: { clock.date })
        let connection = connection()
        _ = try await manager.connect(connection)
        let first = try #require(await manager.catalogDriver(for: connection.id, database: "app") as? MockDatabaseDriver)

        clock.advance(by: ConnectionManager.catalogIdleLimit - 1)
        let reused = await manager.catalogDriver(for: connection.id, database: "app")
        clock.advance(by: ConnectionManager.catalogIdleLimit - 1)
        let stillReused = await manager.catalogDriver(for: connection.id, database: "app")
        clock.advance(by: ConnectionManager.catalogIdleLimit + 1)
        let fresh = await manager.catalogDriver(for: connection.id, database: "app")

        #expect(reused === first)
        #expect(stillReused === first)
        #expect(fresh !== first)
        try await waitUntil(timeout: .seconds(5)) { first.disconnectCount == 1 }
    }

    @Test("A read on a connection that stopped answering drops it and answers nil; a live error is thrown")
    func readDropsADeadConnection() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)
        let catalog = try #require(await manager.catalogDriver(for: connection.id, database: "app") as? MockDatabaseDriver)

        await #expect(throws: (any Error).self) {
            _ = try await manager.readCatalog(for: connection.id, database: "app") { _ -> Int in throw ReadFailure() }
        }
        #expect(catalog.disconnectCount == 0)

        catalog.isConnected = false
        let answer = try await manager.readCatalog(for: connection.id, database: "app") { _ -> Int in throw ReadFailure() }
        #expect(answer == nil)
        #expect(catalog.disconnectCount == 1)
        let read = try await manager.readCatalog(for: connection.id, database: "app") { _ in 7 }
        #expect(read == 7)
    }

    @Test("Switching the session's database closes the catalog connection left in the old one")
    func databaseSwitchClosesTheOldCatalog() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)
        let old = try #require(await manager.catalogDriver(for: connection.id, database: "app") as? MockDatabaseDriver)

        try await manager.switchDatabase(connection.id, to: "sales")

        #expect(old.disconnectCount == 1)
    }

    @Test("Disconnecting the session closes its catalog driver")
    func closedWithTheSession() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)
        let catalog = try #require(
            await manager.catalogDriver(for: connection.id, database: "app") as? MockDatabaseDriver
        )

        await manager.disconnect(connection.id)

        try await waitUntil(timeout: .seconds(5)) { catalog.disconnectCount == 1 }
        #expect(await manager.catalogDriver(for: connection.id, database: "app") == nil)
    }

    @Test("A reconnect replaces the catalog driver with one dialed for the new session")
    func reconnectReplacesIt() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)
        let old = try #require(
            await manager.catalogDriver(for: connection.id, database: "app") as? MockDatabaseDriver
        )

        _ = try await manager.connect(connection)
        let fresh = try #require(await manager.catalogDriver(for: connection.id, database: "app"))

        #expect(fresh !== old)
        try await waitUntil(timeout: .seconds(5)) { old.disconnectCount == 1 }
    }

    @Test("A discarded catalog driver is closed and the next read opens a new one")
    func discardOpensAnew() async throws {
        let factory = DialingDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)
        let stale = try #require(
            await manager.catalogDriver(for: connection.id, database: "app") as? MockDatabaseDriver
        )

        await manager.discardCatalogDriver(stale, for: connection.id)
        let fresh = try #require(await manager.catalogDriver(for: connection.id, database: "app"))

        #expect(stale.disconnectCount == 1)
        #expect(fresh !== stale)
    }
}

private struct ReadFailure: Error {}

private final class SettableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private final class DialingDriverFactory: DriverFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [DatabaseConnection] = []
    private let opensCatalogs: Bool
    var failsConnect = false

    init(opensCatalogs: Bool = true) {
        self.opensCatalogs = opensCatalogs
    }

    var dialed: [DatabaseConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        let driver = MockDatabaseDriver()
        driver.shouldFailConnect = failsConnect
        return driver
    }

    func supportedTypes() -> [DatabaseType] { [DatabaseType(rawValue: "mock")] }

    func opensCatalogConnections(for connection: DatabaseConnection) -> Bool { opensCatalogs }

    private var preparedDrivers: [any DatabaseDriver] = []

    var prepared: [any DatabaseDriver] {
        lock.lock()
        defer { lock.unlock() }
        return preparedDrivers
    }

    func prepareCatalogDriver(_ driver: any DatabaseDriver, for connection: DatabaseConnection) async throws {
        record(driver)
    }

    private func record(_ driver: any DatabaseDriver) {
        lock.lock()
        defer { lock.unlock() }
        preparedDrivers.append(driver)
    }
}
