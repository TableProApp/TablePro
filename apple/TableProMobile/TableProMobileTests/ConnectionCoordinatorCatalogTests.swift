import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProSQLGrammar
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

    @Test("With a PostgreSQL transaction open, the reload reads the session, the one place its DDL shows")
    func openTransactionReadsTheSession() async {
        let session = driver(tables: ["orders"])
        var postgres = connection
        postgres.type = .postgresql
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: postgres, appState: appState)
        await coordinator.connect()
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

    @Test("A session a USE moved off the catalog reloads the list from itself, as Refresh does")
    func movedSessionReloadsFromItself() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        factory.opensCatalogs = true
        factory.queue(driver(tables: ["stale"]))
        appState.catalogChanges.noteSessionEffect(
            .init(leavesCatalog: true), for: connection.id, driver: ObjectIdentifier(session)
        )
        session.scriptedTables = [TableInfo(name: "orders_2019")]

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders_2019"])
        #expect(factory.dialed.count == 1)
    }

    @Test("On MySQL, whose DDL commits itself, a held transaction still reloads on the catalog connection")
    func mysqlTransactionReadsTheCatalog() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        session.scriptedTransactionState = .implicitTransaction
        await coordinator.refreshTransaction()
        factory.opensCatalogs = true
        factory.queue(driver(tables: ["orders", "invoices"]))

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders", "invoices"])
        #expect(factory.dialed.count == 2)
    }

    @Test("A server whose catalog connection cannot open keeps its lists rather than reading the session")
    func unavailableCatalogKeepsTheLists() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        factory.opensCatalogs = true
        session.scriptedTables = [TableInfo(name: "orders"), TableInfo(name: "invoices")]

        coordinator.noteCatalogChanged(.tables)
        await coordinator.reloadChangedCatalog()

        #expect(names(coordinator) == ["orders"])
        #expect(factory.dialed.count == 2)
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

    @Test("A database a stopped run already moved to still moves the picker and the table list")
    func followsTheSessionDatabaseAfterAStop() async {
        let plugin = StubPluginDriver()
        let session = UsedDatabaseDriver(
            plugin: plugin, dialedHosts: [], rowIdentity: .keyColumns, readsOnly: { _ in true },
            cancelsRunningRequest: { try? plugin.cancelQuery() }
        )
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        await coordinator.connect()
        session.used = "archive"

        let stopped = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await coordinator.followSessionDatabase()
        }
        await stopped.value

        #expect(coordinator.activeDatabase == "archive")
        #expect(!coordinator.showFailureAlert)
    }

    @Test("After a USE or a SET ROLE in the editor completion reads the session, a database switch included")
    func useKeepsCompletionOnTheSession() async {
        let session = driver(tables: ["orders"])
        let coordinator = await connected(session)
        #expect(coordinator.catalogMatchesSession)

        appState.catalogChanges.noteSessionEffect(
            .init(leavesCatalog: true), for: connection.id, driver: ObjectIdentifier(session)
        )
        #expect(!coordinator.catalogMatchesSession)

        await coordinator.switchDatabase(to: "archive")
        #expect(coordinator.activeDatabase == "archive")
        #expect(!coordinator.catalogMatchesSession)
    }
}


private final class UsedDatabaseDriver: PluginBackedDriver, @unchecked Sendable {
    var used: String?
    override var currentDatabase: String? { used }
}
