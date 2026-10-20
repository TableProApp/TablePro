import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProQuery
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

    private func warehouseCoordinators(on driver: MockDatabaseDriver) async throws -> (ConnectionCoordinator, ConnectionCoordinator) {
        let warehouse = DatabaseConnection(
            name: "Warehouse",
            type: .postgresql,
            host: "pg.example.com",
            port: 5_432,
            database: "analytics"
        )
        factory.queue(driver)
        _ = try await appState.connectionManager.connect(warehouse)
        let left = ConnectionCoordinator(connection: warehouse, appState: appState)
        await left.connect()
        let right = ConnectionCoordinator(connection: warehouse, appState: appState)
        await right.connect()
        return (left, right)
    }

    private func runQuery(_ text: String, in coordinator: ConnectionCoordinator, on driver: MockDatabaseDriver) async {
        let viewModel = QueryEditorViewModel()
        let script = QueryScript(units: [QueryScript.Unit(sql: text)], unitKind: .statement)
        await coordinator.track(rolledBack: { _ in viewModel.ranTransactionRollBack }) {
            await viewModel.run(driver: driver, script: script)
        }
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

    @Test("A window that opens the connection while another redials it shares that dial, and neither shows an error")
    func freshOpenSharesARedial() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let redialing = await attachedCoordinator()
        let dialsBefore = factory.dialed.count

        let teardown = TestGate()
        first.beforeDisconnect = { await teardown.enter() }
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        let redial = Task { await redialing.reconnectIfNeeded() }
        await teardown.waitUntilEntered()

        let opening = ConnectionCoordinator(connection: connection, appState: appState)
        let fresh = Task { await opening.connect() }
        await teardown.open()
        await redial.value
        await fresh.value

        #expect(factory.dialed.count == dialsBefore + 1)
        #expect(redialing.session?.driver === second)
        #expect(opening.session?.driver === second)
        #expect(isConnected(redialing))
        #expect(isConnected(opening))
        #expect(!redialing.showFailureAlert)
        #expect(!opening.showFailureAlert)
    }

    @Test("A window closed while another window's dial is out leaves that dial running")
    func closingAnotherWindowKeepsTheDial() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let redialing = await attachedCoordinator()

        let teardown = TestGate()
        first.beforeDisconnect = { await teardown.enter() }
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        let redial = Task { await redialing.reconnectIfNeeded() }
        await teardown.waitUntilEntered()

        let closing = ConnectionCoordinator(connection: connection, appState: appState)
        closing.retire()
        await teardown.open()
        await redial.value

        #expect(redialing.session?.driver === second)
        #expect(isConnected(redialing))
        #expect(!redialing.showFailureAlert)
    }

    @Test("A window waiting to share another window's dial keeps it when that window closes")
    func waitingWindowKeepsTheDialItsOpenerLeft() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let redialing = await attachedCoordinator()
        let dialsBefore = factory.dialed.count

        let teardown = TestGate()
        first.beforeDisconnect = { await teardown.enter() }
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        let redial = Task { await redialing.reconnectIfNeeded() }
        await teardown.waitUntilEntered()

        let opening = ConnectionCoordinator(connection: connection, appState: appState)
        let fresh = Task { await opening.connect() }
        // Main-actor hops: the open task, then its attempt, which joins the dial before it first suspends.
        for _ in 0 ..< 20 { await Task.yield() }
        redialing.retire()
        await teardown.open()
        await redial.value
        await fresh.value

        #expect(factory.dialed.count == dialsBefore + 1)
        #expect(opening.session?.driver === second)
        #expect(isConnected(opening))
        #expect(!opening.showFailureAlert)
    }

    @Test("A dial its last window walked away from is delisted, so a retry does not wait on it")
    func abandonedDialIsDelisted() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let redialing = await attachedCoordinator()

        let teardown = TestGate()
        first.beforeDisconnect = { await teardown.enter() }
        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(driver(tables: ["orders"]))
        let redial = Task { await redialing.reconnectIfNeeded() }
        await teardown.waitUntilEntered()

        redialing.retire()
        await appState.sessionRedialer.settled(connection.id)
        await teardown.open()
        await redial.value
    }

    @Test("No window switches database under another window's unsaved row edit")
    func unsavedEditBlocksADatabaseSwitch() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let switching = await attachedCoordinator()
        let editing = await attachedCoordinator()

        editing.isHeldByEditor = true
        await switching.switchDatabase(to: "app_staging")

        #expect(switching.activeDatabase == "app_prod")
        #expect(switching.showFailureAlert)
        #expect(switching.failureAlertMessage == ConnectionCoordinator.editorHeldElsewhereMessage)

        editing.isHeldByEditor = false
        switching.showFailureAlert = false
        await switching.switchDatabase(to: "app_staging")
        #expect(switching.activeDatabase == "app_staging")
    }

    @Test("A window busy with its own switch follows another window's switch once it is free")
    func busyWindowFollowsOnceFree() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let busy = await attachedCoordinator()
        let other = await attachedCoordinator()

        let gate = TestGate()
        first.beforeTransactionState = { await gate.enter() }
        let busySwitch = Task { await busy.switchDatabase(to: "app_staging") }
        await gate.waitUntilEntered()
        first.beforeTransactionState = nil
        first.scriptedTables = [TableInfo(name: "archive_orders")]
        await other.switchDatabase(to: "app_archive")
        await busy.followLiveSession()
        await gate.open()
        await busySwitch.value
        await busy.resumedFollow?.value

        #expect(busy.activeDatabase == "app_archive")
        #expect(tableNames(busy) == ["archive_orders"])
    }

    @Test("A database switch on the shared session moves the other window to that database and its tables")
    func otherWindowFollowsASharedDatabaseSwitch() async throws {
        let first = driver(tables: ["orders"])
        try await dial(first)
        let switching = await attachedCoordinator()
        let following = await attachedCoordinator()
        let revision = appState.sessionRevision(for: connection.id)

        first.scriptedTables = [TableInfo(name: "staging_orders")]
        await switching.switchDatabase(to: "app_staging")
        #expect(appState.sessionRevision(for: connection.id) > revision)
        await following.followLiveSession()

        #expect(following.session?.driver === first)
        #expect(following.activeDatabase == "app_staging")
        #expect(tableNames(following) == ["staging_orders"])
    }

    // A Drop or Truncate confirmation open in one window names a table by where that window stood when it was chosen.
    @Test("Another window's schema switch moves the placement a pending destructive action was chosen in")
    func followMovesTheTablePlacement() async throws {
        let first = driver(tables: ["facts"])
        first.currentSchema = "public"
        let (switching, following) = try await warehouseCoordinators(on: first)
        let chosen = following.tablePlacement

        await switching.switchSchema(to: "staging")
        await following.followLiveSession()

        #expect(chosen.schema == "public")
        #expect(following.tablePlacement.schema == "staging")
        #expect(following.tablePlacement != chosen)
    }

    @Test("A window following a schema switch keeps its old placement until the new schema's tables arrive")
    func followCommitsPlacementWithItsTables() async throws {
        let first = driver(tables: ["facts"])
        first.currentSchema = "public"
        let (switching, following) = try await warehouseCoordinators(on: first)
        await switching.switchSchema(to: "staging")

        let fetch = TestGate()
        first.scriptedTables = [TableInfo(name: "staging_facts")]
        first.beforeFetchTables = { await fetch.enter() }
        let follow = Task { await following.followLiveSession() }
        await fetch.waitUntilEntered()
        let duringFetch = (following.tablePlacement.schema, tableNames(following))
        await fetch.open()
        await follow.value

        #expect(duringFetch.0 == "public")
        #expect(duringFetch.1 == ["facts"])
        #expect(following.tablePlacement.schema == "staging")
        #expect(tableNames(following) == ["staging_facts"])
    }

    @Test("A row edit started while a follow loads tables keeps the old placement until the edit ends")
    func followYieldsToAnEditStartedDuringItsFetch() async throws {
        let first = driver(tables: ["facts"])
        first.currentSchema = "public"
        let (switching, following) = try await warehouseCoordinators(on: first)
        await switching.switchSchema(to: "staging")

        let fetch = TestGate()
        first.scriptedTables = [TableInfo(name: "staging_facts")]
        first.beforeFetchTables = { await fetch.enter() }
        let follow = Task { await following.followLiveSession() }
        await fetch.waitUntilEntered()
        following.isHeldByEditor = true
        first.beforeFetchTables = nil
        await fetch.open()
        await follow.value

        #expect(following.tablePlacement.schema == "public")
        #expect(tableNames(following) == ["facts"])

        following.isHeldByEditor = false
        await following.resumedFollow?.value
        #expect(following.tablePlacement.schema == "staging")
        #expect(tableNames(following) == ["staging_facts"])
    }

    @Test("A follow that another switch overtakes while its tables load lands on the newer placement")
    func followOvertakenBySecondSwitchFollowsTheNewest() async throws {
        let first = driver(tables: ["facts"])
        first.currentSchema = "public"
        let (switching, following) = try await warehouseCoordinators(on: first)
        await switching.switchSchema(to: "staging")

        let fetch = TestGate()
        first.scriptedTables = [TableInfo(name: "staging_facts")]
        first.beforeFetchTables = { await fetch.enter() }
        let follow = Task { await following.followLiveSession() }
        await fetch.waitUntilEntered()
        first.beforeFetchTables = nil
        first.currentSchema = "archive"
        first.scriptedTables = [TableInfo(name: "archive_facts")]
        await fetch.open()
        await follow.value
        let afterOvertaken = following.tablePlacement.schema
        await following.resumedFollow?.value

        #expect(afterOvertaken == "public")
        #expect(following.tablePlacement.schema == "archive")
        #expect(tableNames(following) == ["archive_facts"])
    }

    @Test("A window closed while its database switch waits on another window's dial leaves that dial's session alone")
    func closedWindowSwitchDoesNotTearDownTheSharedSession() async throws {
        let first = driver(tables: ["facts"])
        first.currentSchema = "public"
        let (redialing, switching) = try await warehouseCoordinators(on: first)
        let dialsBefore = factory.dialed.count

        let teardown = TestGate()
        first.beforeDisconnect = { await teardown.enter() }
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["facts"])
        second.currentSchema = "public"
        factory.queue(second)
        let redial = Task { await redialing.reconnectIfNeeded() }
        await teardown.waitUntilEntered()

        let switchTask = Task { await switching.switchDatabase(to: "staging") }
        for _ in 0 ..< 20 { await Task.yield() }
        switching.retire()
        await teardown.open()
        await redial.value
        await switchTask.value

        #expect(factory.dialed.count == dialsBefore + 1)
        #expect(redialing.session?.driver === second)
        #expect(appState.connectionManager.session(for: redialing.connection.id)?.driver === second)
        #expect(isConnected(redialing))
    }

    // SQL Server keeps schemas per database, so the other window's list belongs to the database it left.
    @Test("A window following a SQL Server database switch lists the new database's schemas")
    func followReloadsSchemasForTheNewDatabase() async throws {
        let first = driver(tables: ["orders"])
        first.currentSchema = "dbo"
        first.scriptedSchemas = ["dbo", "sales"]
        let warehouse = DatabaseConnection(name: "Ledger", type: .mssql, host: "sql.example.com", port: 1_433, database: "app")
        factory.queue(first)
        _ = try await appState.connectionManager.connect(warehouse)
        let switching = ConnectionCoordinator(connection: warehouse, appState: appState)
        await switching.connect()
        let following = ConnectionCoordinator(connection: warehouse, appState: appState)
        await following.connect()

        first.scriptedSchemas = ["dbo", "archive"]
        await switching.switchDatabase(to: "history")
        await following.followLiveSession()

        #expect(following.activeDatabase == "history")
        #expect(following.schemas == ["dbo", "archive"])
    }

    @Test("A PostgreSQL database switch in one window moves the other window onto the new session")
    func otherWindowFollowsAPostgreSQLSwitch() async throws {
        let first = driver(tables: ["facts"])
        first.currentSchema = "public"
        let (switching, following) = try await warehouseCoordinators(on: first)

        let second = driver(tables: ["staging_facts"])
        second.currentSchema = "public"
        factory.queue(second)
        await switching.switchDatabase(to: "staging")
        await following.followLiveSession()

        #expect(switching.session?.driver === second)
        #expect(following.session?.driver === second)
        #expect(following.activeDatabase == "staging")
        #expect(tableNames(following) == ["staging_facts"])
    }

    @Test("A typed ROLLBACK that ends the transaction counts as a Roll Back, and a typed COMMIT does not")
    func typedRollBackCountsAsARollBack() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()
        #expect(coordinator.transactionHold == .open)

        first.scriptedTransactionState = .idle
        await runQuery("COMMIT", in: coordinator, on: first)
        #expect(coordinator.transactionHold == nil)
        #expect(monitor.rollBackCount(for: connection.id) == 0)

        first.scriptedTransactionState = .explicitTransaction
        await coordinator.refreshTransaction()
        #expect(coordinator.transactionHold == .open)
        first.scriptedTransactionState = .idle
        await runQuery("ROLLBACK", in: coordinator, on: first)

        #expect(coordinator.transactionHold == nil)
        #expect(monitor.rollBackCount(for: connection.id) == 1)
    }

    @Test("ROLLBACK AND CHAIN counts as a Roll Back though a new transaction is open after it")
    func chainedRollBackCountsAsARollBack() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        try await dial(first)
        let coordinator = await attachedCoordinator()

        await runQuery("ROLLBACK AND CHAIN", in: coordinator, on: first)

        #expect(coordinator.transactionHold == .open)
        #expect(monitor.rollBackCount(for: connection.id) == 1)
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
        #expect(monitor.rollBackCount(for: connection.id) == 0)
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
        // Row screens and grids leave or reload on this, as after a Roll Back that went through.
        #expect(monitor.rollBackCount(for: connection.id) == 1)
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
