import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection coordinator reconnect", .timeLimit(.minutes(1)))
struct ConnectionCoordinatorReconnectTests {
    private let fixture: AppStateFixture
    private let factory = StubDriverFactory()
    private let appState: AppState
    private let connection = DatabaseConnection(
        name: "Prod",
        type: .mysql,
        host: "db.example.com",
        port: 3_306,
        database: "app_prod"
    )

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, driverFactory: factory)
    }

    private var monitor: SessionTransactionMonitor { appState.sessionTransactions }

    private func driver(tables: [String] = [], state: DriverTransactionState = .idle) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedTables = tables.map { TableInfo(name: $0) }
        driver.scriptedTransactionState = state
        return driver
    }

    private func dial(_ driver: MockDatabaseDriver, database: String? = nil) async throws {
        var target = connection
        if let database { target.database = database }
        factory.queue(driver)
        _ = try await appState.connectionManager.connect(target)
    }

    private func attachedCoordinator() async -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        await coordinator.connect()
        return coordinator
    }

    private func isConnected(_ coordinator: ConnectionCoordinator) -> Bool {
        if case .connected = coordinator.phase { return true }
        return false
    }

    private func tableNames(_ coordinator: ConnectionCoordinator) -> [String] {
        coordinator.tables.map { $0.name }
    }

    @Test("A redial dials the database the toolbar shows and reloads its tables")
    func redialDialsTheActiveDatabase() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let coordinator = await attachedCoordinator()
        await coordinator.switchDatabase(to: "app_staging")
        #expect(coordinator.activeDatabase == "app_staging")

        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["staging_orders"])
        factory.queue(second)
        await coordinator.reconnectIfNeeded()

        let dialedDatabase = factory.dialed.last?.database
        #expect(dialedDatabase == "app_staging")
        #expect(coordinator.session?.driver === second)
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(tableNames(coordinator) == ["staging_orders"])
        #expect(isConnected(coordinator))
    }

    @Test("A session another window dialed is taken without a ping, with its database and tables")
    func newerSessionIsAdoptedWithItsDatabase() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let coordinator = await attachedCoordinator()
        #expect(coordinator.activeDatabase == "app_prod")

        let other = driver(tables: ["staging_orders"])
        try await dial(other, database: "app_staging")
        let dialsBefore = factory.dialed.count
        await coordinator.reconnectIfNeeded()

        #expect(first.pingCount == 0)
        #expect(factory.dialed.count == dialsBefore)
        #expect(coordinator.session?.driver === other)
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(tableNames(coordinator) == ["staging_orders"])
    }

    @Test("Two windows coming back at once dial the connection once")
    func twoWindowsDialOnce() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let left = await attachedCoordinator()
        let right = await attachedCoordinator()
        let dialsBefore = factory.dialed.count

        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        async let leftDone: Void = left.reconnectIfNeeded()
        async let rightDone: Void = right.reconnectIfNeeded()
        _ = await (leftDone, rightDone)

        #expect(factory.dialed.count == dialsBefore + 1)
        #expect(left.session?.driver === second)
        #expect(right.session?.driver === second)
        #expect(isConnected(left))
        #expect(isConnected(right))
    }

    @Test("A redial over an open transaction tells the user the server rolled it back")
    func redialOverAHoldShowsTheAlert() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()
        #expect(monitor.hold(for: connection.id) == .open)

        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(driver(tables: ["orders"]))
        await coordinator.reconnectIfNeeded()

        #expect(coordinator.showFailureAlert)
        #expect(coordinator.failureAlertMessage == ConnectionCoordinator.lostTransactionMessage(.whileIdle, connectionName: "Prod"))
        #expect(monitor.hold(for: connection.id) == nil)
    }

    @Test("A redial with nothing held reconnects quietly")
    func redialWithoutAHoldIsQuiet() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let coordinator = await attachedCoordinator()

        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(driver(tables: ["orders"]))
        await coordinator.reconnectIfNeeded()

        #expect(!coordinator.showFailureAlert)
        #expect(isConnected(coordinator))
    }

    @Test("A Commit whose reply is lost redials and says its outcome is not known")
    func failedCommitOnADeadSessionRedials() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()
        #expect(monitor.hold(for: connection.id) == .open)
        let token = try #require(coordinator.transactionToken)

        first.commitError = MockDatabaseDriver.MockError.scripted
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        try await coordinator.commitTransaction(as: token)
        await ObservedCondition.wait { monitor.hold(for: connection.id) == nil }

        #expect(coordinator.session?.driver === second)
        #expect(coordinator.showFailureAlert)
        #expect(coordinator.failureAlertMessage == ConnectionCoordinator.lostTransactionMessage(.duringWork, connectionName: "Prod"))
        #expect(isConnected(coordinator))
    }

    @Test("A foreground check while tracked work is out says the outcome is not known")
    func foregroundCheckDuringWorkIsAmbiguous() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()
        let gate = TestGate()
        let work = Task { await coordinator.track { await gate.enter() } }
        await gate.waitUntilEntered()

        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(driver(tables: ["orders"]))
        await coordinator.reconnectIfNeeded()
        await gate.open()
        await work.value

        #expect(coordinator.failureAlertMessage == ConnectionCoordinator.lostTransactionMessage(.duringWork, connectionName: "Prod"))
    }

    @Test("A Roll Back that loses the connection redials without an alert: the transaction is gone as asked")
    func lostRollBackRedialsQuietly() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()
        let token = try #require(coordinator.transactionToken)

        first.rollbackError = MockDatabaseDriver.MockError.scripted
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        try await coordinator.rollBackTransaction(as: token)
        await ObservedCondition.wait { monitor.hold(for: connection.id) == nil }

        #expect(coordinator.session?.driver === second)
        #expect(!coordinator.showFailureAlert)
    }

    @Test("A window left on a replaced session shows no hold, and its Commit refuses rather than commit the newer one")
    func staleWindowRefusesTheNewerSessionsCommit() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let coordinator = await attachedCoordinator()
        let other = driver(tables: ["staging_orders"], state: .explicitTransaction)
        try await dial(other, database: "app_staging")
        await monitor.refresh(connection.id)

        #expect(monitor.hold(for: connection.id) == .open)
        #expect(coordinator.transactionHold == nil)
        #expect(coordinator.transactionToken == nil)
        await #expect(throws: TransactionActionError.sessionReplaced) {
            try await coordinator.commitTransaction(as: SessionTransactionMonitor.HoldToken(driver: first, workGeneration: 0))
        }

        #expect(!other.didCommitTransaction)
        #expect(coordinator.session?.driver === other)
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(coordinator.transactionHold == .open)
    }

    @Test("Two windows sharing a redial both read the schema it restored")
    func sharedRedialRestoresTheSchemaFirst() async throws {
        let warehouse = DatabaseConnection(
            name: "Warehouse",
            type: .postgresql,
            host: "pg.example.com",
            port: 5_432,
            database: "analytics"
        )
        let first = driver(tables: ["facts"])
        first.currentSchema = "public"
        factory.queue(first)
        _ = try await appState.connectionManager.connect(warehouse)
        let left = ConnectionCoordinator(connection: warehouse, appState: appState)
        await left.connect()
        await left.switchSchema(to: "sales")
        let right = ConnectionCoordinator(connection: warehouse, appState: appState)
        await right.connect()
        #expect(right.activeSchema == "sales")
        let dialsBefore = factory.dialed.count

        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["facts"])
        second.currentSchema = "public"
        factory.queue(second)
        async let leftDone: Void = left.reconnectIfNeeded()
        async let rightDone: Void = right.reconnectIfNeeded()
        _ = await (leftDone, rightDone)

        #expect(factory.dialed.count == dialsBefore + 1)
        #expect(second.currentSchema == "sales")
        #expect(left.activeSchema == "sales")
        #expect(right.activeSchema == "sales")
    }

    @Test("A Roll Back reloads the table list, so a dropped table it undid comes back")
    func rollBackReloadsTables() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()
        first.scriptedTables = []
        await coordinator.refreshTables()
        #expect(coordinator.tables.isEmpty)

        first.scriptedTables = [TableInfo(name: "orders")]
        await coordinator.reloadAfterRollBack()

        #expect(tableNames(coordinator) == ["orders"])
    }

    @Test("Refreshing the table list shows a transaction a read opened")
    func tableRefreshPicksUpAReadTransaction() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let coordinator = await attachedCoordinator()
        #expect(coordinator.transactionHold == nil)

        first.scriptedTransactionState = .implicitTransaction
        await coordinator.refreshTables()

        #expect(coordinator.transactionHold == .open)
    }

    @Test("A Commit refused on a live session reports the error and keeps the session")
    func refusedCommitOnALiveSessionThrows() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()
        first.scriptedTransactionState = .abortedTransaction
        let token = try #require(coordinator.transactionToken)

        await #expect(throws: TransactionActionError.cannotCommit) {
            try await coordinator.commitTransaction(as: token)
        }

        #expect(coordinator.session?.driver === first)
        #expect(monitor.hold(for: connection.id) == .aborted)
        #expect(!coordinator.showFailureAlert)
    }

    @Test("Tracked work that fails on a dead session redials")
    func failedWorkRedials() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let coordinator = await attachedCoordinator()

        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        let ranIntoAnError = await coordinator.track(failed: { $0 }) { true }

        #expect(ranIntoAnError)
        #expect(coordinator.session?.driver === second)
    }

    @Test("A reattached session whose catalog an aborted transaction refuses is kept, and reloads after Roll Back")
    func refusedMetadataReloadsAfterRollBack() async throws {
        let first = driver(state: .abortedTransaction)
        first.fetchTablesError = MockDatabaseDriver.MockError.scripted
        try await dial(first)
        let coordinator = await attachedCoordinator()

        #expect(isConnected(coordinator))
        #expect(coordinator.session?.driver === first)
        #expect(monitor.hold(for: connection.id) == .aborted)
        #expect(coordinator.tables.isEmpty)

        first.fetchTablesError = nil
        first.scriptedTables = [TableInfo(name: "orders")]
        first.scriptedTransactionState = .idle
        try await coordinator.rollBackTransaction(as: #require(coordinator.transactionToken))

        #expect(first.didRollbackTransaction)
        #expect(monitor.hold(for: connection.id) == nil)
        #expect(tableNames(coordinator) == ["orders"])
    }
}
