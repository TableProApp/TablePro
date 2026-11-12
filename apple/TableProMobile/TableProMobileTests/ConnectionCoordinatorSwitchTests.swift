import Foundation
import TableProConnectionLibrary
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection coordinator switch", .timeLimit(.minutes(1)))
struct ConnectionCoordinatorSwitchTests {
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
    private let warehouse = DatabaseConnection(
        name: "Warehouse",
        type: .postgresql,
        host: "pg.example.com",
        port: 5_432,
        database: "analytics"
    )

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, driverFactory: factory)
    }

    private func driver(tables: [String] = []) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedTables = tables.map { TableInfo(name: $0) }
        driver.scriptedTransactionState = .idle
        driver.currentSchema = "public"
        return driver
    }

    private func refusingDriver() -> MockDatabaseDriver {
        let refused = driver()
        refused.connectError = ScriptedFailure.unreachable
        return refused
    }

    private func attachedCoordinator(to record: DatabaseConnection, on first: MockDatabaseDriver) async throws -> ConnectionCoordinator {
        factory.queue(first)
        _ = try await appState.connectionManager.connect(record)
        let coordinator = ConnectionCoordinator(connection: record, appState: appState)
        await coordinator.connect()
        return coordinator
    }

    private func tableNames(_ coordinator: ConnectionCoordinator) -> [String] {
        coordinator.tables.map { $0.name }
    }

    @Test("A switch names its target while it runs, and leaves the screen usable once it ends")
    func switchNamesItsTarget() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(to: connection, on: first)
        let gate = TestGate()
        first.beforeTransactionState = { await gate.enter() }

        let switching = Task { await coordinator.switchDatabase(to: "app_staging") }
        await gate.waitUntilEntered()
        #expect(coordinator.isSwitching)
        #expect(coordinator.switchTarget == "app_staging")

        first.beforeTransactionState = nil
        await gate.open()
        await switching.value
        #expect(!coordinator.isSwitching)
        #expect(coordinator.switchTarget == nil)
    }

    @Test("A switch whose table list fails moves the picker with the session, empties the list and says why")
    func unreadTablesMoveThePickerAndSayWhy() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(to: connection, on: first)

        first.fetchTablesError = ScriptedFailure.refused
        await coordinator.switchDatabase(to: "app_staging")

        #expect(coordinator.activeDatabase == "app_staging")
        #expect(tableNames(coordinator).isEmpty)
        #expect(coordinator.showFailureAlert)
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.refreshTablesFailedTitle)
        #expect(coordinator.failureAlertMessage == ScriptedFailure.refused.localizedDescription)
    }

    @Test("A refused switch keeps the database and its tables, and says why")
    func refusedSwitchKeepsThePlacement() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(to: connection, on: first)

        first.switchDatabaseError = ScriptedFailure.refused
        await coordinator.switchDatabase(to: "app_staging")

        #expect(coordinator.activeDatabase == "app_prod")
        #expect(tableNames(coordinator) == ["orders"])
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.switchDatabaseFailedTitle)
        #expect(coordinator.failureAlertMessage == ScriptedFailure.refused.localizedDescription)
    }

    @Test("A switch that fails on a dead session redials onto the database the picker shows")
    func switchOnADeadSessionRedials() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(to: connection, on: first)

        first.switchDatabaseError = ScriptedFailure.refused
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders"])
        factory.queue(second)
        await coordinator.switchDatabase(to: "app_staging")

        #expect(factory.dialed.last?.database == "app_prod")
        #expect(coordinator.session?.driver === second)
        #expect(coordinator.activeDatabase == "app_prod")
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.switchDatabaseFailedTitle)
    }

    @Test("A failed PostgreSQL switch returns to the database the picker shows, not the saved one, and says why")
    func failedPostgreSQLSwitchReturnsWhereItWas() async throws {
        let coordinator = try await attachedCoordinator(to: warehouse, on: driver(tables: ["facts"]))
        factory.queue(driver(tables: ["staging_facts"]))
        await coordinator.switchDatabase(to: "staging")
        #expect(coordinator.activeDatabase == "staging")

        let fallback = driver(tables: ["staging_facts"])
        factory.queue(refusingDriver())
        factory.queue(fallback)
        await coordinator.switchDatabase(to: "archive")

        #expect(factory.dialed.suffix(2).map { $0.database } == ["archive", "staging"])
        #expect(coordinator.session?.driver === fallback)
        #expect(coordinator.activeDatabase == "staging")
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastDB.name(for: warehouse.id)) == "staging")
        #expect(tableNames(coordinator) == ["staging_facts"])
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.switchDatabaseFailedTitle)
        #expect(coordinator.failureAlertMessage == ScriptedFailure.unreachable.localizedDescription)
    }

    @Test("A PostgreSQL switch whose way back fails too leaves a lost session, not a failed connect")
    func failedFallbackIsLost() async throws {
        let coordinator = try await attachedCoordinator(to: warehouse, on: driver(tables: ["facts"]))
        factory.queue(refusingDriver())
        factory.queue(refusingDriver())

        await coordinator.switchDatabase(to: "archive")

        #expect(coordinator.session == nil)
        #expect(coordinator.displayStatus == .lost(cause: ScriptedFailure.unreachable.localizedDescription))
    }

    @Test("An open whose saved database cannot be restored, and whose way back fails too, is lost and redials on the next trigger")
    func failedRestoreDuringAnOpenIsLost() async {
        let lastDB = ConnectionDefaultsKey.lastDB.name(for: warehouse.id)
        UserDefaults.standard.set("staging", forKey: lastDB)
        defer { UserDefaults.standard.removeObject(forKey: lastDB) }
        let first = driver(tables: ["facts"])
        first.scriptedDatabases = ["analytics", "staging"]
        factory.queue(first)
        factory.queue(refusingDriver())
        factory.queue(refusingDriver())
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.suffix(2).map { $0.database } == ["staging", "analytics"])
        #expect(coordinator.session == nil)
        #expect(coordinator.displayStatus == .lost(cause: ScriptedFailure.unreachable.localizedDescription))

        let recovered = driver(tables: ["facts"])
        factory.queue(recovered)
        await coordinator.reconnectIfNeeded()

        #expect(factory.dialed.last?.database == "analytics")
        #expect(coordinator.session?.driver === recovered)
        #expect(coordinator.displayStatus == .connected)
    }

    @Test("A refresh that fails on a dead session redials and shows the new list without an alert")
    func refreshOnADeadSessionRedials() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(to: connection, on: first)

        first.fetchTablesError = MockDatabaseDriver.MockError.scripted
        first.pingError = MockDatabaseDriver.MockError.scripted
        let second = driver(tables: ["orders", "invoices"])
        factory.queue(second)
        await coordinator.refreshTables()

        #expect(coordinator.session?.driver === second)
        #expect(tableNames(coordinator) == ["orders", "invoices"])
        #expect(!coordinator.showFailureAlert)
    }

    @Test("A refresh refused on a live session keeps the list and says why")
    func refusedRefreshSaysWhy() async throws {
        let first = driver(tables: ["orders"])
        let coordinator = try await attachedCoordinator(to: connection, on: first)

        first.fetchTablesError = ScriptedFailure.refused
        await coordinator.refreshTables()

        #expect(coordinator.session?.driver === first)
        #expect(tableNames(coordinator) == ["orders"])
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.refreshTablesFailedTitle)
        #expect(coordinator.failureAlertMessage == ScriptedFailure.refused.localizedDescription)
    }
}
