import Foundation
import TableProConnectionLibrary
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection coordinator status", .timeLimit(.minutes(1)))
struct ConnectionCoordinatorStatusTests {
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
    private let failure = AppError(
        category: .network,
        title: "Connection Failed",
        message: "The server closed the connection.",
        recovery: nil,
        underlying: nil
    )

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, driverFactory: factory)
    }

    private func driver(tables: [String] = [], state: DriverTransactionState = .idle) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedTables = tables.map { TableInfo(name: $0) }
        driver.scriptedTransactionState = state
        return driver
    }

    private func refusingDriver() -> MockDatabaseDriver {
        let refused = driver()
        refused.connectError = ScriptedFailure.unreachable
        return refused
    }

    private func attachedCoordinator(on first: MockDatabaseDriver) async throws -> ConnectionCoordinator {
        factory.queue(first)
        _ = try await appState.connectionManager.connect(connection)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        await coordinator.connect()
        return coordinator
    }

    private func lostCoordinator(on first: MockDatabaseDriver) async throws -> ConnectionCoordinator {
        let coordinator = try await attachedCoordinator(on: first)
        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(refusingDriver())
        await coordinator.reconnectIfNeeded()
        return coordinator
    }

    private func isConnected(_ coordinator: ConnectionCoordinator) -> Bool {
        if case .connected = coordinator.phase { return true }
        return false
    }

    // MARK: - Mapping

    @Test("Each phase maps to the shared display status, and a redial reads as reconnecting")
    func phaseMapsToTheDisplayStatus() {
        #expect(ConnectionDisplayStatus(phase: .notConnected, isReconnecting: false) == .notConnected)
        #expect(ConnectionDisplayStatus(phase: .connecting, isReconnecting: false) == .connecting)
        #expect(ConnectionDisplayStatus(phase: .connected, isReconnecting: false) == .connected)
        #expect(ConnectionDisplayStatus(phase: .connected, isReconnecting: true) == .reconnecting(attempt: 1, of: 1))
        #expect(ConnectionDisplayStatus(phase: .failed(failure), isReconnecting: false) == .failed(cause: failure.message))
        #expect(ConnectionDisplayStatus(phase: .lost(failure), isReconnecting: false) == .lost(cause: failure.message))
        #expect(ConnectionDisplayStatus(phase: .lost(failure), isReconnecting: true) == .reconnecting(attempt: 1, of: 1))
    }

    @Test("Only the resting states carry a title of their own, and neither carries a mark")
    func restingStatesAreUnmarked() {
        let resting: [ConnectionDisplayStatus] = [.connected, .notConnected]
        for status in resting {
            #expect(status.restingTitle != nil)
            #expect(ConnectionStatusPresentation(status).symbol == nil)
        }
        let active: [ConnectionDisplayStatus] = [.connecting, .reconnecting(attempt: 1, of: 1), .lost(cause: nil), .failed(cause: nil)]
        for status in active {
            #expect(status.restingTitle == nil)
            #expect(ConnectionStatusPresentation(status).title != nil)
        }
    }

    // MARK: - Cancel

    @Test("Cancelling a connect leaves a neutral not-connected state that offers Connect")
    func cancelIsNeutral() async {
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        let dialed = driver(tables: ["orders"])
        let connecting = TestGate()
        dialed.beforeConnect = { await connecting.enter() }
        factory.queue(dialed)
        let connect = Task { await coordinator.connect() }
        await connecting.waitUntilEntered()

        coordinator.cancelConnect()
        await connecting.open()
        await connect.value

        #expect(coordinator.displayStatus == .notConnected)
        let presentation = ConnectionStatusPresentation(coordinator.displayStatus)
        #expect(presentation.primaryAction == .connect)
        #expect(presentation.symbol == nil)
        #expect(coordinator.session == nil)
    }

    // MARK: - Lost session

    @Test("A failed reconnect leaves a lost session naming its cause, and the next trigger dials the database it was on")
    func lostSessionRedialsOnTheNextTrigger() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(on: first)
        await coordinator.switchDatabase(to: "app_staging")
        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(refusingDriver())
        await coordinator.reconnectIfNeeded()

        #expect(coordinator.session == nil)
        #expect(coordinator.displayStatus == .lost(cause: ScriptedFailure.unreachable.localizedDescription))
        #expect(!coordinator.showFailureAlert)

        let second = driver(tables: ["staging_orders"])
        factory.queue(second)
        await coordinator.reconnectIfNeeded()

        #expect(factory.dialed.last?.database == "app_staging")
        #expect(coordinator.session?.driver === second)
        #expect(coordinator.tables.map { $0.name } == ["staging_orders"])
        #expect(coordinator.displayStatus == .connected)
    }

    @Test("Cancel during a lost session's redial ends it, and a dial that returns late is not adopted")
    func cancelStopsALostSessionsRedial() async throws {
        let coordinator = try await lostCoordinator(on: driver(tables: ["orders"]))
        let late = driver(tables: ["orders"])
        let dialing = TestGate()
        late.beforeConnect = { await dialing.enter() }
        factory.queue(late)
        let recovery = Task { await coordinator.reconnectIfNeeded() }
        await dialing.waitUntilEntered()
        guard case .connecting = ConnectedScreen.resolve(
            phase: coordinator.phase, isReconnecting: coordinator.isReconnecting, isHeldByEditor: false
        ) else {
            Issue.record("Expected the connecting screen while the lost session redials")
            return
        }

        coordinator.cancelConnect()
        await dialing.open()
        await recovery.value

        #expect(coordinator.session == nil)
        #expect(coordinator.displayStatus == .notConnected)
        #expect(!coordinator.isReconnecting)
        #expect(late.connectSawCancellation)

        await coordinator.reconnectIfNeeded()
        #expect(coordinator.session == nil)
    }

    @Test("Reconnect on a lost session redials it in place")
    func reconnectRedialsALostSession() async throws {
        let coordinator = try await lostCoordinator(on: driver(tables: ["orders"]))
        let second = driver(tables: ["orders"])
        factory.queue(second)

        await coordinator.reconnect()

        #expect(coordinator.session?.driver === second)
        #expect(isConnected(coordinator))
    }

    @Test("Tracked work that fails on a lost session dials again")
    func failedWorkOnALostSessionRedials() async throws {
        let coordinator = try await lostCoordinator(on: driver(tables: ["orders"]))
        let second = driver(tables: ["orders"])
        factory.queue(second)

        _ = await coordinator.track(failed: { $0 }) { true }

        #expect(coordinator.session?.driver === second)
        #expect(isConnected(coordinator))
    }

    @Test("A redial that lands after a failed one says the server rolled back the open transaction")
    func laterRedialReportsTheDroppedTransaction() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        let coordinator = try await lostCoordinator(on: first)
        #expect(!coordinator.showFailureAlert)
        #expect(appState.sessionTransactions.rollBackCount(for: connection.id) == 0)

        factory.queue(driver(tables: ["orders"]))
        await coordinator.reconnectIfNeeded()

        #expect(coordinator.showFailureAlert)
        #expect(coordinator.failureAlertMessage == ConnectionCoordinator.lostTransactionMessage(.whileIdle, connectionName: "Prod"))
        #expect(appState.sessionTransactions.rollBackCount(for: connection.id) == 1)
    }

    @Test("A window whose redial failed takes the session another window dialed")
    func lostWindowFollowsAnotherWindowsDial() async throws {
        let lost = try await lostCoordinator(on: driver(tables: ["orders"]))
        let other = ConnectionCoordinator(connection: connection, appState: appState)
        let second = driver(tables: ["orders"])
        factory.queue(second)
        await other.connect()
        let dialsBefore = factory.dialed.count

        await lost.followLiveSession()

        #expect(factory.dialed.count == dialsBefore)
        #expect(lost.session?.driver === second)
        #expect(isConnected(lost))
    }

    // MARK: - Grid reads

    @Test("A grid page that fails on a dead session redials, and a transaction lost under it was lost while idle")
    func failedPageReadRedials() async throws {
        let first = driver(tables: ["orders"], state: .explicitTransaction)
        let coordinator = try await attachedCoordinator(on: first)
        let viewModel = DataBrowserViewModel()
        viewModel.attach(
            session: coordinator.session,
            table: TableInfo(name: "orders"),
            databaseType: .mysql,
            host: connection.host,
            trackRead: coordinator.trackPageRead { viewModel.loadError != nil }
        )

        first.fetchColumnsError = MockDatabaseDriver.MockError.scripted
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        await viewModel.load(isInitial: true)

        #expect(coordinator.session?.driver === second)
        #expect(coordinator.failureAlertMessage == ConnectionCoordinator.lostTransactionMessage(.whileIdle, connectionName: "Prod"))
    }

    @Test("A grid page that fails on a live session keeps the session")
    func failedPageReadOnALiveSessionKeepsIt() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(on: first)
        let viewModel = DataBrowserViewModel()
        viewModel.attach(
            session: coordinator.session,
            table: TableInfo(name: "orders"),
            databaseType: .mysql,
            host: connection.host,
            trackRead: coordinator.trackPageRead { viewModel.loadError != nil }
        )
        let dialsBefore = factory.dialed.count

        first.fetchColumnsError = MockDatabaseDriver.MockError.scripted
        await viewModel.load(isInitial: true)

        #expect(viewModel.loadError != nil)
        #expect(first.pingCount == 1)
        #expect(factory.dialed.count == dialsBefore)
        #expect(coordinator.session?.driver === first)
    }

    // MARK: - Row screens

    private func rowScreen(
        on coordinator: ConnectionCoordinator,
        safeModeLevel: SafeModeLevel = .off,
        value: String = "Charlie"
    ) -> RowDetailViewModel {
        let columns = [
            ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
        ]
        let viewModel = RowDetailViewModel(
            columns: columns,
            rows: [Row(cells: [.text("1"), .text("Alice")])],
            initialIndex: 0,
            table: TableInfo(name: "users"),
            session: coordinator.session,
            columnDetails: columns,
            databaseType: .mysql,
            safeModeLevel: { safeModeLevel },
            liveSession: { coordinator.writableSession }
        )
        viewModel.startEditing()
        viewModel.setEditedValue(value, at: 1)
        return viewModel
    }

    private func ranUpdate(_ driver: MockDatabaseDriver) -> Bool {
        driver.executedQueries.contains { $0.uppercased().hasPrefix("UPDATE") }
    }

    @Test("A row edit left open across a redial saves on the new driver")
    func rowSaveAfterARedialReachesTheNewDriver() async throws {
        let first = driver(tables: ["users"])
        let coordinator = try await attachedCoordinator(on: first)
        let viewModel = rowScreen(on: coordinator)

        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["users"])
        factory.queue(second)
        await coordinator.reconnectIfNeeded()
        #expect(coordinator.session?.driver === second)

        let saved = await coordinator.track(failed: { _ in viewModel.operationError != nil }) {
            await viewModel.saveChanges()
        }

        #expect(saved)
        #expect(viewModel.operationError == nil)
        #expect(ranUpdate(second))
        #expect(!ranUpdate(first))
    }

    // Built under NO_BACKSLASH_ESCAPES, 'C:\temp' would store a tab on a default session.
    @Test("A row save confirmed after a redial is built again with the new session's escaping")
    func confirmedRowSaveIsRebuiltForTheNewSession() async throws {
        let first = driver(tables: ["users"])
        first.usesBackslashEscaping = false
        let coordinator = try await attachedCoordinator(on: first)
        let viewModel = rowScreen(on: coordinator, safeModeLevel: .confirmWrites, value: "C:\\temp")
        _ = await viewModel.saveChanges()
        #expect(viewModel.pendingWriteConfirmation)

        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["users"])
        second.usesBackslashEscaping = true
        factory.queue(second)
        await coordinator.reconnectIfNeeded()
        let saved = await viewModel.executePendingSave()

        #expect(saved)
        #expect(!ranUpdate(first))
        let update = try #require(second.executedQueries.first { $0.uppercased().hasPrefix("UPDATE") })
        #expect(update.contains("'C:\\\\temp'"))
        #expect(!update.contains("'C:\\temp'"))
    }

    @Test("A row save with the session lost fails with the lost state, and its redial lets the next save land")
    func rowSaveOnALostSessionSaysLost() async throws {
        let first = driver(tables: ["users"])
        let coordinator = try await attachedCoordinator(on: first)
        let viewModel = rowScreen(on: coordinator)
        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(refusingDriver())
        await coordinator.reconnectIfNeeded()
        #expect(coordinator.session == nil)

        let second = driver(tables: ["users"])
        factory.queue(second)
        let saved = await coordinator.track(failed: { _ in viewModel.operationError != nil }) {
            await viewModel.saveChanges()
        }

        #expect(!saved)
        #expect(viewModel.operationError?.title == ConnectionStatusPresentation(.lost(cause: nil)).title)
        #expect(viewModel.operationError?.message == ScriptedFailure.unreachable.localizedDescription)
        #expect(!ranUpdate(first))
        #expect(coordinator.session?.driver === second)

        viewModel.operationError = nil
        #expect(await viewModel.saveChanges())
        #expect(ranUpdate(second))
    }

    // A window on app_staging whose redial failed; `beforeLoss` runs while it is still connected.
    private func lostOnStaging(
        beforeLoss: (ConnectionCoordinator) -> Void = { _ in }
    ) async throws -> ConnectionCoordinator {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(on: first)
        first.scriptedTables = [TableInfo(name: "staging_orders")]
        await coordinator.switchDatabase(to: "app_staging")
        beforeLoss(coordinator)
        first.pingError = MockDatabaseDriver.MockError.scripted
        factory.queue(refusingDriver())
        await coordinator.reconnectIfNeeded()
        #expect(coordinator.session == nil)
        return coordinator
    }

    // Another window opens the connection, which dials the saved app_prod.
    private func reconnectAnotherWindow() async -> MockDatabaseDriver {
        let second = driver(tables: ["orders"])
        factory.queue(second)
        await ConnectionCoordinator(connection: connection, appState: appState).connect()
        #expect(appState.connectionManager.session(for: connection.id)?.activeDatabase == "app_prod")
        return second
    }

    @Test("A lost window with an unsaved edit leaves another window's session on another database alone until the edit ends")
    func editPinsALostWindowAgainstAnotherDatabase() async throws {
        var editor: RowDetailViewModel?
        let coordinator = try await lostOnStaging { connected in
            editor = rowScreen(on: connected)
            connected.isHeldByEditor = true
        }
        let viewModel = try #require(editor)
        let second = await reconnectAnotherWindow()

        await coordinator.followLiveSession()
        await coordinator.reconnectIfNeeded()
        let saved = await viewModel.saveChanges()

        #expect(coordinator.session == nil)
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(coordinator.tables.map { $0.name } == ["staging_orders"])
        #expect(!saved)
        #expect(!ranUpdate(second))

        coordinator.isHeldByEditor = false
        await coordinator.resumedFollow?.value

        #expect(coordinator.session?.driver === second)
        #expect(coordinator.activeDatabase == "app_prod")
        #expect(coordinator.tables.map { $0.name } == ["orders"])
        #expect(isConnected(coordinator))
    }

    @Test("An unsaved edit that starts while a lost window loads another database's tables keeps the window where it was")
    func editArrivingDuringTheFetchPinsTheWindow() async throws {
        let coordinator = try await lostOnStaging()
        let second = await reconnectAnotherWindow()
        let loading = TestGate()
        second.beforeFetchTables = { await loading.enter() }

        let check = Task { await coordinator.reconnectIfNeeded() }
        await loading.waitUntilEntered()
        coordinator.isHeldByEditor = true
        second.beforeFetchTables = nil
        await loading.open()
        await check.value

        #expect(coordinator.session == nil)
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(coordinator.tables.map { $0.name } == ["staging_orders"])

        coordinator.isHeldByEditor = false
        await coordinator.resumedFollow?.value

        #expect(coordinator.session?.driver === second)
        #expect(coordinator.activeDatabase == "app_prod")
    }

    @Test("A planned insert is built with the escaping of whichever driver runs it")
    func plannedInsertUsesEachDriversEscaping() throws {
        let columns = [
            ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
        ]
        let write = PlannedRowWrite.insert(
            table: "users", schema: nil, type: .mysql, columns: columns, values: ["name": .text("C:\\temp")]
        )
        let backslash = driver()
        backslash.usesBackslashEscaping = true
        let ansi = driver()

        let onBackslash = try #require(try write.batch(on: backslash)).statements.joined()
        let onAnsi = try #require(try write.batch(on: ansi)).statements.joined()

        #expect(onBackslash.contains("'C:\\\\temp'"))
        #expect(onAnsi.contains("'C:\\temp'"))
        #expect(!onAnsi.contains("\\\\"))
    }
}

nonisolated enum ScriptedFailure: LocalizedError {
    case unreachable
    case refused

    var errorDescription: String? {
        switch self {
        case .unreachable: "Lost connection to the server during the query"
        case .refused: "The server refused the request"
        }
    }
}
