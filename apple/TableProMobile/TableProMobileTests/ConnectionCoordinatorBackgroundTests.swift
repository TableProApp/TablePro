import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection coordinator after the background", .timeLimit(.minutes(1)))
struct ConnectionCoordinatorBackgroundTests {
    private let fixture: AppStateFixture
    private let factory = StubDriverFactory()
    private let appState: AppState
    private let connection = DatabaseConnection(name: "Ledger", type: .duckdb, host: "", port: 0, database: "ledger.duckdb")

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, driverFactory: factory)
    }

    private var monitor: SessionTransactionMonitor { appState.sessionTransactions }

    private func fileDriver(_ state: DriverTransactionState) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedTables = [TableInfo(name: "entries")]
        driver.scriptedTransactionState = state
        driver.holdsSuspensionBlockingResource = true
        return driver
    }

    private func connectedCoordinator(on driver: MockDatabaseDriver) async throws -> ConnectionCoordinator {
        factory.queue(driver)
        _ = try await appState.connectionManager.connect(connection)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        await coordinator.connect()
        return coordinator
    }

    // What the app runs at `.background`, then the session's end reaching the monitor.
    private func releaseForTheBackground() async {
        let released = await appState.connectionManager.releaseSuspensionBlockingResources()
        #expect(released == [connection.id])
        await ObservedCondition.wait { monitor.hold(for: connection.id) == nil }
    }

    @Test("A transaction open when the app went to the background is reported once the file reopens")
    func backgroundCloseReportsTheTransaction() async throws {
        let coordinator = try await connectedCoordinator(on: fileDriver(.explicitTransaction))
        #expect(coordinator.transactionHold == .open)

        await releaseForTheBackground()
        let reopened = fileDriver(.idle)
        factory.queue(reopened)
        await coordinator.reconnectIfNeeded()

        #expect(coordinator.session?.driver === reopened)
        #expect(coordinator.showFailureAlert)
        #expect(
            coordinator.failureAlertMessage
                == ConnectionCoordinator.lostTransactionMessage(.inBackground, connectionName: "Ledger")
        )
        #expect(monitor.rollBackCount(for: connection.id) == 1)
    }

    @Test("A file session with nothing open reopens after the background without an alert")
    func idleBackgroundCloseIsQuiet() async throws {
        let coordinator = try await connectedCoordinator(on: fileDriver(.idle))

        await releaseForTheBackground()
        let reopened = fileDriver(.idle)
        factory.queue(reopened)
        await coordinator.reconnectIfNeeded()

        #expect(coordinator.session?.driver === reopened)
        #expect(!coordinator.showFailureAlert)
        #expect(monitor.rollBackCount(for: connection.id) == 0)
    }

    @Test("A statement still running when the app went to the background leaves the outcome unknown, in a file's terms")
    func backgroundCloseDuringWorkIsAmbiguous() async throws {
        let coordinator = try await connectedCoordinator(on: fileDriver(.explicitTransaction))
        let gate = TestGate()
        let work = Task { await coordinator.track { await gate.enter() } }
        await gate.waitUntilEntered()

        await releaseForTheBackground()
        await gate.open()
        await work.value
        factory.queue(fileDriver(.idle))
        await coordinator.reconnectIfNeeded()

        let message = try #require(coordinator.failureAlertMessage)
        #expect(message == ConnectionCoordinator.lostTransactionMessage(.inBackgroundAfterStatement, connectionName: "Ledger"))
        #expect(message != ConnectionCoordinator.lostTransactionMessage(.duringWork, connectionName: "Ledger"))
    }

    @Test("A statement on the closed file while the window checks the session leaves the roll back certain")
    func statementAfterTheReturnKeepsTheRollBackCertain() async throws {
        let coordinator = try await connectedCoordinator(on: fileDriver(.explicitTransaction))
        await releaseForTheBackground()

        let gate = TestGate()
        let work = Task { await coordinator.track { await gate.enter() } }
        await gate.waitUntilEntered()
        factory.queue(fileDriver(.idle))
        await coordinator.reconnectIfNeeded()
        await gate.open()
        await work.value

        #expect(
            coordinator.failureAlertMessage
                == ConnectionCoordinator.lostTransactionMessage(.inBackground, connectionName: "Ledger")
        )
    }

    @Test("A reopen that fails keeps the loss and reports it when a later reopen lands")
    func failedReopenReportsLater() async throws {
        let coordinator = try await connectedCoordinator(on: fileDriver(.explicitTransaction))

        await releaseForTheBackground()
        let refused = fileDriver(.idle)
        refused.connectError = MockDatabaseDriver.MockError.scripted
        factory.queue(refused)
        await coordinator.reconnectIfNeeded()
        #expect(!coordinator.showFailureAlert)

        factory.queue(fileDriver(.idle))
        await coordinator.reconnectIfNeeded()

        #expect(
            coordinator.failureAlertMessage
                == ConnectionCoordinator.lostTransactionMessage(.inBackground, connectionName: "Ledger")
        )
    }
}
