import Foundation
import TableProConnectionLibrary
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
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

    private func missingDatabaseDriver() -> MockDatabaseDriver {
        let refused = driver()
        refused.connectError = ScriptedFailure.noSuchDatabase
        return refused
    }

    private func mySQLDriver(tables: [String]) -> MockDatabaseDriver {
        let session = driver(tables: tables)
        session.currentSchema = nil
        session.scriptedDatabases = ["app_prod", "app_staging"]
        return session
    }

    private func mySQLFamily(_ type: DatabaseType) -> DatabaseConnection {
        DatabaseConnection(name: "Prod", type: type, host: "db.example.com", port: 3_306, database: "app_prod")
    }

    private func postgreSQLDriver(tables: [String]) -> MockDatabaseDriver {
        let session = driver(tables: tables)
        session.scriptedDatabases = ["analytics", "staging"]
        session.scriptedSchemas = ["public", "sales"]
        return session
    }

    // Where the connection was when it last closed, which the first window restores.
    private func remember(database: String, schema: String? = nil, for record: DatabaseConnection) {
        UserDefaults.standard.set(database, forKey: ConnectionDefaultsKey.lastDB.name(for: record.id))
        if let schema {
            UserDefaults.standard.set(schema, forKey: ConnectionDefaultsKey.lastSchema.name(for: record.id))
        }
    }

    private func forget(_ record: DatabaseConnection) {
        UserDefaults.standard.removeObject(forKey: ConnectionDefaultsKey.lastDB.name(for: record.id))
        UserDefaults.standard.removeObject(forKey: ConnectionDefaultsKey.lastSchema.name(for: record.id))
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

    @Test("An open whose remembered and saved databases both refuse fails as a connect does, and the next connect dials the remembered one again")
    func refusedRememberedAndSavedDatabasesFailTheOpen() async {
        remember(database: "staging", for: warehouse)
        defer { forget(warehouse) }
        factory.queue(missingDatabaseDriver())
        factory.queue(refusingDriver())
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging", "analytics"])
        #expect(coordinator.session == nil)
        #expect(coordinator.displayStatus == .failed(cause: ScriptedFailure.unreachable.localizedDescription))
        #expect(!coordinator.showFailureAlert)

        let recovered = driver(tables: ["staging_facts"])
        factory.queue(recovered)
        await coordinator.connect()

        #expect(factory.dialed.count == 3)
        #expect(factory.dialed.last?.database == "staging")
        #expect(coordinator.session?.driver === recovered)
        #expect(coordinator.activeDatabase == "staging")
        #expect(coordinator.displayStatus == .connected)
    }

    // MARK: - Open

    @Test("A PostgreSQL open dials the remembered database once, restores the schema inside the dial and reads each list once")
    func openDialsTheRememberedPlacement() async {
        remember(database: "staging", schema: "sales", for: warehouse)
        defer { forget(warehouse) }
        let session = postgreSQLDriver(tables: ["sales_facts"])
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging"])
        #expect(session.switchedSchemas == ["sales"])
        #expect(session.fetchTablesSchemas == [nil])
        #expect(session.fetchSchemasCalls == 1)
        #expect(session.fetchDatabasesCalls == 1)
        #expect(session.transactionStateReads == 1)
        #expect(coordinator.session?.driver === session)
        #expect(coordinator.activeDatabase == "staging")
        #expect(coordinator.activeSchema == "sales")
        #expect(coordinator.schemas == ["public", "sales"])
        #expect(tableNames(coordinator) == ["sales_facts"])
        #expect(!coordinator.showFailureAlert)
    }

    @Test(
        "A MySQL-family open dials the remembered database once, with no USE, and reads each list once",
        arguments: [DatabaseType.mysql, .mariadb, .tidb]
    )
    func mySQLFamilyOpenDialsTheRememberedDatabase(_ type: DatabaseType) async {
        let record = mySQLFamily(type)
        remember(database: "app_staging", for: record)
        defer { forget(record) }
        let session = mySQLDriver(tables: ["staging_orders"])
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: record, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_staging"])
        #expect(session.switchedDatabases.isEmpty)
        #expect(session.fetchTablesSchemas == [nil])
        #expect(session.fetchDatabasesCalls == 1)
        #expect(session.transactionStateReads == 1)
        #expect(coordinator.session?.driver === session)
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(coordinator.tableQualifier == "app_staging")
        #expect(tableNames(coordinator) == ["staging_orders"])
        #expect(!coordinator.showFailureAlert)
    }

    // A contained SQL Server user signs in against the database the login names; OceanBase is unmeasured.
    @Test(
        "A SQL Server or OceanBase open dials the saved database and moves to the remembered one with USE",
        arguments: [DatabaseType.mssql, .oceanbase]
    )
    func useEngineOpenDialsTheSavedDatabase(_ type: DatabaseType) async {
        let record = DatabaseConnection(name: "Ledger", type: type, host: "db.example.com", port: 1_433, database: "app")
        remember(database: "history", for: record)
        defer { forget(record) }
        let session = driver(tables: ["orders"])
        session.currentSchema = "dbo"
        session.scriptedSchemas = ["dbo"]
        session.scriptedDatabases = ["app", "history"]
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: record, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app"])
        #expect(session.switchedDatabases == ["history"])
        #expect(coordinator.activeDatabase == "history")
        #expect(!coordinator.showFailureAlert)
    }

    @Test("A MySQL database refused at sign-in falls back to the saved one, whose USE says why as an open always did")
    func refusedMySQLDatabaseFallsBackToUse() async {
        remember(database: "app_staging", for: connection)
        defer { forget(connection) }
        let refused = driver()
        refused.connectError = MySQLError.databaseRefused("Access denied for user 'app'@'%' to database 'app_staging'")
        let saved = mySQLDriver(tables: ["orders"])
        let useRefusal = MySQLError.queryFailed("Access denied for user 'app'@'%' to database 'app_staging'")
        saved.switchDatabaseError = useRefusal
        factory.queue(refused)
        factory.queue(saved)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_staging", "app_prod"])
        #expect(coordinator.session?.driver === saved)
        #expect(coordinator.displayStatus == .connected)
        #expect(coordinator.activeDatabase == "app_prod")
        #expect(tableNames(coordinator) == ["orders"])
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.switchDatabaseFailedTitle)
        #expect(coordinator.failureAlertMessage == useRefusal.localizedDescription)
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id)) == "app_staging")
    }

    @Test("A MySQL database the server no longer lists falls back quietly and is forgotten")
    func droppedMySQLDatabaseIsForgotten() async {
        remember(database: "app_archive", for: connection)
        defer { forget(connection) }
        let refused = driver()
        refused.connectError = MySQLError.databaseRefused("Unknown database 'app_archive'")
        let saved = mySQLDriver(tables: ["orders"])
        factory.queue(refused)
        factory.queue(saved)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_archive", "app_prod"])
        #expect(coordinator.session?.driver === saved)
        #expect(saved.switchedDatabases.isEmpty)
        #expect(coordinator.activeDatabase == "app_prod")
        #expect(!coordinator.showFailureAlert)
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id)) == nil)
    }

    @Test("A MySQL sign-in refused on the remembered database fails the open after one dial, and the next open dials the saved one and moves with USE")
    func refusedMySQLSignInDialsOnce() async {
        remember(database: "app_staging", for: connection)
        defer { forget(connection) }
        let denied = driver()
        let refusal = MySQLError.connectionFailed("Access denied for user 'app'@'10.0.0.2' (using password: YES)")
        denied.connectError = refusal
        let saved = mySQLDriver(tables: ["staging_orders"])
        factory.queue(denied)
        factory.queue(saved)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_staging"])
        #expect(coordinator.session == nil)
        #expect(coordinator.displayStatus == .failed(cause: refusal.localizedDescription))

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_staging", "app_prod"])
        #expect(coordinator.session?.driver === saved)
        #expect(saved.switchedDatabases == ["app_staging"])
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(coordinator.displayStatus == .connected)
    }

    // Another server speaking the protocol may number a missing database its own way, as 1105.
    @Test("A MySQL dial refused in a way it cannot pin on the database fails once, and the next open forgets one no longer listed")
    func unrecognizedMySQLRefusalYieldsToTheSavedDatabase() async {
        remember(database: "app_archive", for: connection)
        defer { forget(connection) }
        let refused = driver()
        let refusal = MySQLError.connectionFailed("Unknown database 'app_archive'")
        refused.connectError = refusal
        factory.queue(refused)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_archive"])
        #expect(coordinator.displayStatus == .failed(cause: refusal.localizedDescription))

        let saved = mySQLDriver(tables: ["orders"])
        factory.queue(saved)
        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_archive", "app_prod"])
        #expect(coordinator.session?.driver === saved)
        #expect(saved.switchedDatabases.isEmpty)
        #expect(coordinator.activeDatabase == "app_prod")
        #expect(!coordinator.showFailureAlert)
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id)) == nil)
    }

    @Test("A MySQL database whose table list is refused falls back to the saved one and moves there with USE")
    func refusedMySQLTableListFallsBackToUse() async {
        remember(database: "app_staging", for: connection)
        defer { forget(connection) }
        let refusing = driver()
        refusing.fetchTablesError = ScriptedFailure.refused
        let saved = mySQLDriver(tables: ["staging_orders"])
        factory.queue(refusing)
        factory.queue(saved)
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["app_staging", "app_prod"])
        #expect(appState.connectionManager.session(for: connection.id)?.driver === saved)
        #expect(saved.switchedDatabases == ["app_staging"])
        #expect(coordinator.activeDatabase == "app_staging")
        #expect(tableNames(coordinator) == ["staging_orders"])
        #expect(!coordinator.showFailureAlert)
    }

    @Test("A remembered database that refuses the open falls back to the saved one once and says why")
    func refusedRememberedDatabaseFallsBackOnce() async {
        remember(database: "staging", for: warehouse)
        defer { forget(warehouse) }
        let fallback = postgreSQLDriver(tables: ["facts"])
        factory.queue(missingDatabaseDriver())
        factory.queue(fallback)
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging", "analytics"])
        #expect(coordinator.session?.driver === fallback)
        #expect(coordinator.displayStatus == .connected)
        #expect(coordinator.activeDatabase == "analytics")
        #expect(tableNames(coordinator) == ["facts"])
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.switchDatabaseFailedTitle)
        #expect(coordinator.failureAlertMessage == ScriptedFailure.noSuchDatabase.localizedDescription)
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastDB.name(for: warehouse.id)) == "staging")
    }

    @Test("A remembered database that never answered fails the open once, and the next open starts from the saved one")
    func hungRememberedDatabaseYieldsToTheSavedOne() async {
        remember(database: "staging", for: warehouse)
        defer { forget(warehouse) }
        let hung = driver()
        hung.connectError = PostgreSQLError.unreachable("Connection timed out.")
        factory.queue(hung)
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging"])
        #expect(coordinator.session == nil)

        let saved = driver(tables: ["facts"])
        factory.queue(saved)
        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging", "analytics"])
        #expect(coordinator.session?.driver === saved)
        #expect(coordinator.displayStatus == .connected)
    }

    @Test("A remembered database the open cannot reach fails it after one dial, without dialing the saved one")
    func unreachableRememberedDatabaseDialsOnce() async {
        remember(database: "staging", for: warehouse)
        defer { forget(warehouse) }
        factory.queue(refusingDriver())
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging"])
        #expect(coordinator.session == nil)
        #expect(coordinator.displayStatus == .failed(cause: ScriptedFailure.unreachable.localizedDescription))

        let recovered = driver(tables: ["staging_facts"])
        factory.queue(recovered)
        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging", "staging"])
        #expect(coordinator.session?.driver === recovered)
        #expect(coordinator.displayStatus == .connected)
    }

    @Test("A PostgreSQL refusal goes to the saved database unless it came from the network, the device or the sign-in")
    func fallbackFollowsTheRefusal() {
        #expect(ConnectionSessionModel.mayBlameDatabase(ScriptedFailure.noSuchDatabase))
        #expect(ConnectionSessionModel.mayBlameDatabase(ScriptedFailure.refused))
        #expect(ConnectionSessionModel.mayBlameDatabase(Refusal(message: "permission denied for database \"staging\"")))
        #expect(ConnectionSessionModel.mayBlameDatabase(Refusal(message: "FATAL:  la base de données « staging » n'existe pas")))
        #expect(!ConnectionSessionModel.mayBlameDatabase(ScriptedFailure.unreachable))
        #expect(!ConnectionSessionModel.mayBlameDatabase(URLError(.timedOut)))
        #expect(!ConnectionSessionModel.mayBlameDatabase(POSIXError(.ETIMEDOUT)))
        #expect(!ConnectionSessionModel.mayBlameDatabase(PostgreSQLError.unreachable("연결 시간이 초과되었습니다.")))
        #expect(!ConnectionSessionModel.mayBlameDatabase(SSHTunnelError.hostKeyRejected("db.example.com")))
        #expect(!ConnectionSessionModel.mayBlameDatabase(CancellationError()))
        #expect(!ConnectionSessionModel.mayBlameDatabase(Refusal(message: "password authentication failed for user \"app\"")))
        #expect(!ConnectionSessionModel.mayBlameDatabase(Refusal(
            message: "password authentication failed for user \"app\"\nno pg_hba.conf entry for host \"10.0.0.2\", user \"app\", database \"staging\", no encryption"
        )))
        #expect(!ConnectionSessionModel.mayBlameDatabase(Refusal(message: "could not translate host name \"db.example\" to address")))
    }

    @Test("A remembered database whose table list is refused falls back to the saved one and says why")
    func refusedRememberedTableListFallsBack() async {
        remember(database: "staging", for: warehouse)
        defer { forget(warehouse) }
        let refusing = driver()
        refusing.fetchTablesError = ScriptedFailure.refused
        let fallback = postgreSQLDriver(tables: ["facts"])
        factory.queue(refusing)
        factory.queue(fallback)
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging", "analytics"])
        #expect(appState.connectionManager.session(for: warehouse.id)?.driver === fallback)
        #expect(coordinator.session?.driver === fallback)
        #expect(coordinator.activeDatabase == "analytics")
        #expect(coordinator.failureAlertTitle == ConnectionCoordinator.switchDatabaseFailedTitle)
        #expect(coordinator.failureAlertMessage == ScriptedFailure.refused.localizedDescription)
    }

    @Test("A remembered database the server no longer lists falls back quietly and is forgotten")
    func droppedRememberedDatabaseIsForgotten() async {
        remember(database: "archive", for: warehouse)
        defer { forget(warehouse) }
        let fallback = postgreSQLDriver(tables: ["facts"])
        factory.queue(missingDatabaseDriver())
        factory.queue(fallback)
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["archive", "analytics"])
        #expect(coordinator.session?.driver === fallback)
        #expect(coordinator.activeDatabase == "analytics")
        #expect(!coordinator.showFailureAlert)
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastDB.name(for: warehouse.id)) == nil)
    }

    @Test("A SQL Server open that needs a sign-in dials the saved database once and offers it")
    func signInOnTheRememberedDatabaseSkipsTheFallback() async throws {
        let ledger = DatabaseConnection(name: "Ledger", type: .mssql, host: "sql.example.com", port: 1_433, database: "app")
        remember(database: "history", for: ledger)
        defer { forget(ledger) }
        let expired = driver()
        expired.connectError = EntraOAuthError.signInRequired
        factory.queue(expired)
        let coordinator = ConnectionCoordinator(connection: ledger, appState: appState)
        coordinator.restorePersistedState()

        let open = Task { await coordinator.connect() }
        await ObservedCondition.wait { coordinator.prompts.current != nil }
        let offer = try #require(coordinator.prompts.current)
        coordinator.prompts.answer(offer.id, accepted: false)
        await open.value

        #expect(factory.dialed.map { $0.database } == ["app"])
        #expect(coordinator.session == nil)
        #expect(!coordinator.showFailureAlert)
        guard case .failed = coordinator.phase else {
            Issue.record("Expected the declined sign-in to fail the open")
            return
        }
    }

    // lastSchema is kept per connection, so it can name a schema of another database.
    @Test("A remembered schema the database does not list is not restored")
    func unlistedRememberedSchemaStaysUnrestored() async {
        remember(database: "staging", schema: "etl", for: warehouse)
        defer { forget(warehouse) }
        let session = postgreSQLDriver(tables: ["staging_facts"])
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["staging"])
        #expect(session.switchedSchemas.isEmpty)
        #expect(session.fetchSchemasCalls == 1)
        #expect(coordinator.activeSchema == "public")
        #expect(tableNames(coordinator) == ["staging_facts"])
    }

    @Test("A PostgreSQL open with nothing remembered dials the saved database and switches nothing")
    func openWithNothingRememberedDialsTheSavedDatabase() async {
        let session = postgreSQLDriver(tables: ["facts"])
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: warehouse, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(factory.dialed.map { $0.database } == ["analytics"])
        #expect(session.switchedSchemas.isEmpty)
        #expect(session.fetchTablesSchemas == [nil])
        #expect(session.fetchSchemasCalls == 1)
        #expect(session.fetchDatabasesCalls == 1)
        #expect(session.transactionStateReads == 1)
        #expect(coordinator.activeDatabase == "analytics")
        #expect(coordinator.activeSchema == "public")
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastDB.name(for: warehouse.id)) == nil)
        #expect(UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastSchema.name(for: warehouse.id)) == nil)
    }

    // The placement's schema reads "public" until a session says otherwise.
    @Test("A SQL Server open with nothing remembered stays on the server's default schema")
    func sqlServerOpenKeepsItsDefaultSchema() async {
        let ledger = DatabaseConnection(name: "Ledger", type: .mssql, host: "sql.example.com", port: 1_433, database: "app")
        let session = driver(tables: ["orders"])
        session.currentSchema = "dbo"
        session.scriptedSchemas = ["dbo", "sales"]
        factory.queue(session)
        let coordinator = ConnectionCoordinator(connection: ledger, appState: appState)
        coordinator.restorePersistedState()

        await coordinator.connect()

        #expect(session.switchedSchemas.isEmpty)
        #expect(session.fetchSchemasCalls == 1)
        #expect(coordinator.activeSchema == "dbo")
        #expect(coordinator.schemas == ["dbo", "sales"])
        #expect(tableNames(coordinator) == ["orders"])
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

private struct Refusal: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
