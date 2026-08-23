import Testing
import UIKit
import TableProDatabase
import TableProModels
@testable import TableProMobile

@MainActor
private final class SpyBackgroundTaskAsserter: BackgroundTaskAsserting {
    let identifier = UIBackgroundTaskIdentifier(rawValue: 7)
    private(set) var beginCount = 0
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
    private var expirationHandler: (() -> Void)?

    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        beginCount += 1
        self.expirationHandler = expirationHandler
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        endedIdentifiers.append(identifier)
    }

    func fireExpiration() {
        expirationHandler?()
    }
}

private final class StubDriverFactory: DriverFactory, @unchecked Sendable {
    var drivers: [String: any DatabaseDriver] = [:]

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        guard let driver = drivers[connection.type.rawValue] else {
            throw ConnectionError.driverNotFound(connection.type.rawValue)
        }
        return driver
    }

    func supportedTypes() -> [DatabaseType] { [] }
}

private func makeConnection(_ type: String) -> DatabaseConnection {
    DatabaseConnection(name: "Test", type: DatabaseType(rawValue: type))
}

private func makeManager(_ factory: StubDriverFactory) -> ConnectionManager {
    ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
}

private actor Gate {
    private var isOpen = false
    private var hasEntered = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        hasEntered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in blocked { waiter.resume() }
        blocked.removeAll()
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
}

private func makeBlockingDriver() -> MockDatabaseDriver {
    let driver = MockDatabaseDriver()
    driver.holdsSuspensionBlockingResource = true
    return driver
}

@Suite("BackgroundReleaseCoordinator Tests")
@MainActor
struct BackgroundReleaseCoordinatorTests {
    @Test("No assertion is taken when no session holds a resource")
    func noAssertionWithoutBlockingSession() async throws {
        let factory = StubDriverFactory()
        factory.drivers["remote"] = MockDatabaseDriver()
        let manager = makeManager(factory)
        _ = try await manager.connect(makeConnection("remote"))

        let asserter = SpyBackgroundTaskAsserter()
        let coordinator = BackgroundReleaseCoordinator(connectionManager: manager, asserter: asserter)

        coordinator.prepareForSuspension()

        #expect(asserter.beginCount == 0)
    }

    @Test("Preparing takes one assertion and cancelling ends it")
    func assertionTakenOnceAndEndedOnCancel() async throws {
        let factory = StubDriverFactory()
        factory.drivers["file"] = makeBlockingDriver()
        let manager = makeManager(factory)
        _ = try await manager.connect(makeConnection("file"))

        let asserter = SpyBackgroundTaskAsserter()
        let coordinator = BackgroundReleaseCoordinator(connectionManager: manager, asserter: asserter)

        coordinator.prepareForSuspension()
        coordinator.prepareForSuspension()
        #expect(asserter.beginCount == 1)

        coordinator.cancelPreparation()
        #expect(asserter.endedIdentifiers == [asserter.identifier])
    }

    @Test("Returning to the foreground leaves the session connected")
    func cancelledPreparationKeepsSession() async throws {
        let factory = StubDriverFactory()
        factory.drivers["file"] = makeBlockingDriver()
        let manager = makeManager(factory)
        let connection = makeConnection("file")
        _ = try await manager.connect(connection)

        let asserter = SpyBackgroundTaskAsserter()
        let coordinator = BackgroundReleaseCoordinator(connectionManager: manager, asserter: asserter)

        coordinator.prepareForSuspension()
        coordinator.cancelPreparation()

        #expect(manager.session(for: connection.id) != nil)
    }

    @Test("Releasing disconnects only the blocking session and ends the assertion")
    func releaseDisconnectsBlockingSession() async throws {
        let factory = StubDriverFactory()
        factory.drivers["file"] = makeBlockingDriver()
        factory.drivers["remote"] = MockDatabaseDriver()
        let manager = makeManager(factory)
        let fileConnection = makeConnection("file")
        let remoteConnection = makeConnection("remote")
        _ = try await manager.connect(fileConnection)
        _ = try await manager.connect(remoteConnection)

        let asserter = SpyBackgroundTaskAsserter()
        let coordinator = BackgroundReleaseCoordinator(connectionManager: manager, asserter: asserter)

        coordinator.prepareForSuspension()
        await coordinator.releaseForSuspension()

        #expect(manager.session(for: fileConnection.id) == nil)
        #expect(manager.session(for: remoteConnection.id) != nil)
        #expect(asserter.beginCount == 1)
        #expect(asserter.endedIdentifiers == [asserter.identifier])
    }

    @Test("Releasing takes an assertion when preparation was skipped")
    func releaseTakesAssertionWithoutPreparation() async throws {
        let factory = StubDriverFactory()
        factory.drivers["file"] = makeBlockingDriver()
        let manager = makeManager(factory)
        _ = try await manager.connect(makeConnection("file"))

        let asserter = SpyBackgroundTaskAsserter()
        let coordinator = BackgroundReleaseCoordinator(connectionManager: manager, asserter: asserter)

        await coordinator.releaseForSuspension()

        #expect(asserter.beginCount == 1)
        #expect(asserter.endedIdentifiers == [asserter.identifier])
    }

    @Test("Returning to the foreground keeps the assertion while a release is still in flight")
    func inFlightReleaseSurvivesForegroundBounce() async throws {
        let factory = StubDriverFactory()
        let driver = makeBlockingDriver()
        let gate = Gate()
        driver.beforeDisconnect = { await gate.enter() }
        factory.drivers["file"] = driver
        let manager = makeManager(factory)
        _ = try await manager.connect(makeConnection("file"))

        let asserter = SpyBackgroundTaskAsserter()
        let coordinator = BackgroundReleaseCoordinator(connectionManager: manager, asserter: asserter)

        coordinator.prepareForSuspension()
        let release = Task { await coordinator.releaseForSuspension() }
        await gate.waitUntilEntered()

        coordinator.cancelPreparation()
        #expect(asserter.endedIdentifiers.isEmpty)

        await gate.open()
        await release.value

        #expect(asserter.beginCount == 1)
        #expect(asserter.endedIdentifiers == [asserter.identifier])
    }

    @Test("Expiring ends the assertion without ending it twice")
    func expirationEndsAssertionOnce() async throws {
        let factory = StubDriverFactory()
        factory.drivers["file"] = makeBlockingDriver()
        let manager = makeManager(factory)
        _ = try await manager.connect(makeConnection("file"))

        let asserter = SpyBackgroundTaskAsserter()
        let coordinator = BackgroundReleaseCoordinator(connectionManager: manager, asserter: asserter)

        coordinator.prepareForSuspension()
        asserter.fireExpiration()
        coordinator.cancelPreparation()

        #expect(asserter.endedIdentifiers == [asserter.identifier])
    }
}
