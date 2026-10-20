import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection coordinator catalog reload", .timeLimit(.minutes(1)))
struct ConnectionCoordinatorCatalogTests {
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

    private func driver(tables: [String]) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedTables = tables.map { TableInfo(name: $0) }
        driver.scriptedTransactionState = .idle
        return driver
    }

    private func connected(_ session: MockDatabaseDriver) async -> ConnectionCoordinator {
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        await coordinator.connect()
        return coordinator
    }

    private func names(_ coordinator: ConnectionCoordinator) -> [String] {
        coordinator.tables.map { $0.name }
    }

    @Test("A table change reloads the list on the catalog connection, not the session")
    func reloadsOnTheCatalogConnection() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        factory.opensCatalogs = true
        factory.queue(driver(tables: ["orders", "invoices"]))
        session.scriptedTables = [TableInfo(name: "stale")]

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders", "invoices"])
        #expect(factory.dialed.count == 2)
    }

    @Test("Without a catalog connection the session reloads the list")
    func reloadsOnTheSession() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        session.scriptedTables = [TableInfo(name: "orders"), TableInfo(name: "invoices")]

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders", "invoices"])
    }

    @Test("A failed reload keeps the list")
    func failedReloadKeepsTheList() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        session.fetchTablesError = MockDatabaseDriver.MockError.scripted

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders"])
    }

    @Test("Every window on the connection reloads once for a change one of them posted")
    func otherWindowsReload() async {
        let session = driver(tables: ["orders"])
        let first = await connected(session)
        let second = ConnectionCoordinator(connection: connection, appState: appState)
        await second.connect()
        session.scriptedTables = [TableInfo(name: "orders"), TableInfo(name: "invoices")]

        first.noteCatalogChanged(.tables)
        await first.reloadChangedCatalog()
        await second.reloadChangedCatalog()
        session.scriptedTables = [TableInfo(name: "later")]
        await second.reloadChangedCatalog()

        #expect(names(first) == ["orders", "invoices"])
        #expect(names(second) == ["orders", "invoices"])
    }

    @Test("A window opened after a change does not reload for it")
    func newWindowSkipsOldChanges() async {
        let session = driver(tables: ["orders"])
        let first = await connected(session)
        first.noteCatalogChanged(.tables)
        let late = ConnectionCoordinator(connection: connection, appState: appState)
        await late.connect()
        session.scriptedTables = [TableInfo(name: "after")]

        await late.reloadChangedCatalog()

        #expect(names(late) == ["orders"])
    }

    @Test("With a transaction open, the reload reads the session, the one place its DDL shows")
    func openTransactionReadsTheSession() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        session.scriptedTransactionState = .explicitTransaction
        await coordinator.refreshTransaction()
        factory.opensCatalogs = true
        factory.queue(driver(tables: ["orders", "dropped_in_txn"]))
        session.scriptedTables = [TableInfo(name: "orders"), TableInfo(name: "created_in_txn")]

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders", "created_in_txn"])
        #expect(factory.dialed.count == 1)
    }

    @Test("A reload that would read a busy session waits until it is idle")
    func busySessionWaits() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        session.scriptedTables = [TableInfo(name: "orders"), TableInfo(name: "invoices")]
        let gate = TestGate()
        let page = Task { await appState.sessionTransactions.track(connection.id, reading: true) { await gate.enter() } }
        await gate.waitUntilEntered()

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()
        let whileBusy = names(coordinator)
        await gate.open()
        await page.value
        await coordinator.reloadChangedCatalog()

        #expect(whileBusy == ["orders"])
        #expect(names(coordinator) == ["orders", "invoices"])
    }

    @Test("The window that already reloaded its session skips its own post")
    func posterSkipsItsOwnReload() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        session.scriptedTables = [TableInfo(name: "later")]

        coordinator.noteCatalogChanged(.tables, reloadedHere: true)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders"])
    }

    @Test("A schema change reloads the schema list too")
    func schemaChangeReloadsSchemas() async {
        let session = driver(tables: ["orders"])
        session.scriptedSchemas = ["public"]
        var postgres = connection
        postgres.type = .postgresql
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: postgres, appState: appState)
        await coordinator.connect()
        session.scriptedSchemas = ["public", "sales"]

        coordinator.noteCatalogChanged([.schemas, .objects])
        await coordinator.reloadChangedCatalog()

        #expect(coordinator.schemas == ["public", "sales"])
    }
}
