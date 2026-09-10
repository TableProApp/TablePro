import Foundation
@testable import TableProDatabase
@testable import TableProModels
import Testing


@Suite("ConnectionManager Tests")
struct ConnectionManagerTests {
    @Test("Connect creates a session")
    func connectCreatesSession() async throws {
        let factory = MockDriverFactory()
        factory.drivers["mock"] = MockDatabaseDriver()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock"),
            host: "localhost",
            port: 5_432
        )

        let session = try await manager.connect(connection)
        #expect(session.connectionId == connection.id)
        #expect(session.activeDatabase == connection.database)

        let retrieved = manager.session(for: connection.id)
        #expect(retrieved != nil)
    }

    @Test("Disconnect removes session")
    func disconnectRemovesSession() async throws {
        let factory = MockDriverFactory()
        factory.drivers["mock"] = MockDatabaseDriver()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )

        _ = try await manager.connect(connection)
        await manager.disconnect(connection.id)

        let session = manager.session(for: connection.id)
        #expect(session == nil)
    }

    @Test("Reconnecting for the same id tears down the previous session")
    func reconnectDisconnectsPrevious() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )

        let first = MockDatabaseDriver()
        factory.drivers["mock"] = first
        _ = try await manager.connect(connection)

        let second = MockDatabaseDriver()
        factory.drivers["mock"] = second
        _ = try await manager.connect(connection)

        #expect(first.disconnectCount == 1)
        #expect(second.isConnected)
        #expect(manager.session(for: connection.id)?.driver === second)
    }

    @Test("Connect with unknown type throws driverNotFound")
    func connectUnknownType() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "nonexistent")
        )

        await #expect(throws: ConnectionError.self) {
            _ = try await manager.connect(connection)
        }
    }

    @Test("Connect with SSH but no provider throws error")
    func connectSSHNoProvider() async throws {
        let factory = MockDriverFactory()
        factory.drivers["mock"] = MockDatabaseDriver()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store, sshProvider: nil)

        var connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )
        connection.sshEnabled = true
        connection.sshConfiguration = SSHConfiguration(host: "jump.example.com")

        await #expect(throws: ConnectionError.self) {
            _ = try await manager.connect(connection)
        }
    }

    @Test("SSH tunnel cleanup on connect failure")
    func sshTunnelCleanupOnFailure() async throws {
        let factory = MockDriverFactory()
        let failingDriver = MockDatabaseDriver()
        failingDriver.shouldFailConnect = true
        factory.drivers["mock"] = failingDriver

        let store = MockSecureStore()
        let sshProvider = MockSSHProvider()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store, sshProvider: sshProvider)

        var connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )
        connection.sshEnabled = true
        connection.sshConfiguration = SSHConfiguration(host: "jump.example.com")

        await #expect(throws: Error.self) {
            _ = try await manager.connect(connection)
        }

        #expect(sshProvider.closedTunnelIds.count == 1)
        #expect(sshProvider.closedTunnels.isEmpty)
    }

    @Test("A losing attempt closes its own tunnel, never the tunnel the winner installed")
    func losingAttemptClosesOnlyItsOwnTunnel() async throws {
        let factory = MockDriverFactory()
        let ssh = MockSSHProvider()
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(),
            sshProvider: ssh
        )
        let connection = DatabaseConnection(
            name: "Tunnelled",
            type: DatabaseType(rawValue: "mock"),
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "jump.example.com")
        )
        let gate = Gate()

        let slow = MockDatabaseDriver()
        slow.beforeConnect = { await gate.enter() }
        factory.drivers["mock"] = slow

        let losing = Task { _ = try await manager.connect(connection) }
        await gate.waitUntilEntered()

        factory.drivers["mock"] = MockDatabaseDriver()
        _ = try await manager.connect(connection)
        let winningTunnel = ssh.openedTunnelIds[1]

        await gate.open()
        await #expect(throws: CancellationError.self) { try await losing.value }

        #expect(ssh.closedTunnelIds == [ssh.openedTunnelIds[0]])
        #expect(!ssh.closedTunnelIds.contains(winningTunnel))
    }

    @Test("Only sessions holding a suspension blocking resource are released")
    func releaseOnlyTouchesBlockingSessions() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let blockingDriver = MockDatabaseDriver()
        blockingDriver.holdsSuspensionBlockingResource = true
        factory.drivers["blocking"] = blockingDriver
        let blocking = DatabaseConnection(name: "File", type: DatabaseType(rawValue: "blocking"))
        _ = try await manager.connect(blocking)

        let remoteDriver = MockDatabaseDriver()
        factory.drivers["remote"] = remoteDriver
        let remote = DatabaseConnection(name: "Remote", type: DatabaseType(rawValue: "remote"))
        _ = try await manager.connect(remote)

        #expect(manager.hasSuspensionBlockingResources)

        await manager.releaseSuspensionBlockingResources()

        #expect(blockingDriver.disconnectCount == 1)
        #expect(remoteDriver.disconnectCount == 0)
        #expect(manager.session(for: blocking.id) == nil)
        #expect(manager.session(for: remote.id) != nil)
        #expect(!manager.hasSuspensionBlockingResources)
    }

    @Test("Releasing several blocking sessions runs them concurrently")
    func releaseRunsConcurrently() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)
        let barrier = Barrier(expected: 2)

        let firstDriver = MockDatabaseDriver()
        firstDriver.holdsSuspensionBlockingResource = true
        firstDriver.beforeDisconnect = { await barrier.arriveAndWait() }
        factory.drivers["first"] = firstDriver
        _ = try await manager.connect(DatabaseConnection(name: "First", type: DatabaseType(rawValue: "first")))

        let secondDriver = MockDatabaseDriver()
        secondDriver.holdsSuspensionBlockingResource = true
        secondDriver.beforeDisconnect = { await barrier.arriveAndWait() }
        factory.drivers["second"] = secondDriver
        _ = try await manager.connect(DatabaseConnection(name: "Second", type: DatabaseType(rawValue: "second")))

        await manager.releaseSuspensionBlockingResources()

        #expect(await barrier.overlapped == 2)
        #expect(firstDriver.disconnectCount == 1)
        #expect(secondDriver.disconnectCount == 1)
    }

    @Test("A teardown still in flight keeps counting as a blocking resource")
    func inFlightTeardownStillBlocks() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)
        let connection = DatabaseConnection(name: "File", type: DatabaseType(rawValue: "mock"))
        let gate = Gate()

        let driver = MockDatabaseDriver()
        driver.holdsSuspensionBlockingResource = true
        driver.beforeDisconnect = { await gate.enter() }
        factory.drivers["mock"] = driver
        _ = try await manager.connect(connection)

        let teardown = Task { await manager.disconnect(connection.id) }
        await gate.waitUntilEntered()

        #expect(manager.session(for: connection.id) == nil)
        #expect(manager.hasSuspensionBlockingResources)

        await gate.open()
        await teardown.value

        #expect(!manager.hasSuspensionBlockingResources)
    }

    @Test("Connecting waits for an in-flight teardown of the same connection")
    func connectWaitsForInFlightTeardown() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)
        let connection = DatabaseConnection(name: "Test", type: DatabaseType(rawValue: "mock"))
        let gate = Gate()

        let first = MockDatabaseDriver()
        first.beforeDisconnect = { await gate.enter() }
        factory.drivers["mock"] = first
        _ = try await manager.connect(connection)

        let teardown = Task { await manager.disconnect(connection.id) }
        await gate.waitUntilEntered()

        let second = MockDatabaseDriver()
        factory.drivers["mock"] = second
        let reconnect = Task { try await manager.connect(connection) }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!second.isConnected)

        await gate.open()
        _ = try await reconnect.value
        await teardown.value

        #expect(first.disconnectCount == 1)
        #expect(second.isConnected)
    }

    @Test("An attempt invalidated while it is connecting discards its own driver")
    func invalidatedAttemptDiscardsItsDriver() async throws {
        let factory = MockDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = DatabaseConnection(name: "Test", type: DatabaseType(rawValue: "mock"))
        let gate = Gate()

        let driver = MockDatabaseDriver()
        driver.beforeConnect = { await gate.enter() }
        factory.drivers["mock"] = driver

        let attempt = Task { try await manager.connect(connection) }
        await gate.waitUntilEntered()

        manager.invalidateAttempt(for: connection.id)
        await gate.open()

        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(manager.session(for: connection.id) == nil)
        #expect(driver.disconnectCount == 1)
    }

    @Test("A late attempt cannot overwrite the session a newer attempt established")
    func lateAttemptCannotClobberNewerSession() async throws {
        let factory = MockDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = DatabaseConnection(name: "Test", type: DatabaseType(rawValue: "mock"))
        let gate = Gate()

        let slow = MockDatabaseDriver()
        slow.beforeConnect = { await gate.enter() }
        factory.drivers["mock"] = slow

        let first = Task { try await manager.connect(connection) }
        await gate.waitUntilEntered()

        let fast = MockDatabaseDriver()
        factory.drivers["mock"] = fast
        _ = try await manager.connect(connection)

        await gate.open()
        await #expect(throws: CancellationError.self) { try await first.value }

        #expect(manager.session(for: connection.id)?.driver === fast)
        #expect(slow.disconnectCount == 1)
    }

    @Test("A tunnel is opened for the connection being dialed, not for whoever asked last")
    func tunnelCarriesItsOwnConnectionId() async throws {
        let factory = MockDriverFactory()
        let ssh = MockSSHProvider()
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(),
            sshProvider: ssh
        )
        var connection = DatabaseConnection(name: "Tunnelled", type: DatabaseType(rawValue: "mock"))
        connection.sshEnabled = true
        connection.sshConfiguration = SSHConfiguration(host: "jump.example.com", port: 22, username: "probe")
        factory.drivers["mock"] = MockDatabaseDriver()

        _ = try await manager.connect(connection)

        #expect(ssh.tunnelledConnectionIds == [connection.id])
    }
}
