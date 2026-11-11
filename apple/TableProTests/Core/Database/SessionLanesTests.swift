//
//  SessionLanesTests.swift
//  TableProTests
//
//  An engine that cannot change database on a live connection used to reconnect on every switch
//  between two database entries, dropping the transaction, temp tables and settings of the database
//  it left. Each browsed database now keeps its own connection, and a switch moves between them.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import Testing

@Suite("Session lanes", .serialized)
@MainActor
struct SessionLanesTests {

    private final class Opener {
        var opened: [String: MockDatabaseDriver] = [:]
        var openCount = 0
        var failure: Error?
        var schemaForNextOpen: String?
        var inOrder: [MockDatabaseDriver] = []
        var holdsNextOpen: AsyncGate?

        func open(_ scope: DatabaseScope) async throws -> DatabaseDriver {
            openCount += 1
            if let failure { throw failure }
            let driver = MockDatabaseDriver()
            driver.currentSchema = schemaForNextOpen
            opened[scope.database] = driver
            inOrder.append(driver)
            if let gate = holdsNextOpen {
                holdsNextOpen = nil
                await gate.wait()
            }
            return driver
        }
    }

    private struct Harness {
        let connection: DatabaseConnection
        let home: MockDatabaseDriver
        let opener: Opener
        let typeId: String
    }

    /// Reopens its connection to change database and can open a second one, like PostgreSQL. Each
    /// case registers a type of its own, so one case's cleanup never unregisters another's.
    private func registerType() -> String {
        let typeId = "SessionLaneFake-\(UUID().uuidString)"
        let defaults = PluginMetadataSnapshot.CapabilityFlags.defaults
        let capabilities = PluginMetadataSnapshot.CapabilityFlags(
            supportsSchemaSwitching: true,
            supportsImport: defaults.supportsImport,
            supportsExport: defaults.supportsExport,
            supportsSSH: defaults.supportsSSH,
            supportsSSL: defaults.supportsSSL,
            supportsCascadeDrop: defaults.supportsCascadeDrop,
            supportsForeignKeyDisable: defaults.supportsForeignKeyDisable,
            supportsReadOnlyMode: defaults.supportsReadOnlyMode,
            supportsQueryProgress: defaults.supportsQueryProgress,
            requiresReconnectForDatabaseSwitch: true,
            supportsDropDatabase: defaults.supportsDropDatabase
        )
        let snapshot = PluginMetadataSnapshot(
            displayName: typeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "sessionlanefake", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["sessionlanefake"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: capabilities, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId)
        return typeId
    }

    /// A connected session browsing `app` on `home`, with lane opens answered by `opener`.
    private func makeHarness() -> Harness {
        let typeId = registerType()
        var connection = TestFixtures.makeConnection(database: "app")
        connection.type = DatabaseType(rawValue: typeId)
        let home = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: home)
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let opener = Opener()
        let connectionId = connection.id
        /// The lanes are shared with every suite running alongside this one, so only this
        /// connection's opens are answered here.
        DatabaseManager.shared.sessionLanes.opener = { scope in
            guard scope.connectionId == connectionId else {
                return try await MetadataConnectionPool.openServerDriver(for: scope, purpose: .session)
            }
            return try await opener.open(scope)
        }
        return Harness(connection: connection, home: home, opener: opener, typeId: typeId)
    }

    private func cleanUp(_ harness: Harness) {
        DatabaseManager.shared.removeSession(for: harness.connection.id)
        DatabaseManager.shared.sessionLanes.opener = { scope in
            try await MetadataConnectionPool.openServerDriver(for: scope, purpose: .session)
        }
        AppSettingsStorage.shared.saveLastDatabase(nil, for: harness.connection.id)
        AppSettingsStorage.shared.saveLastSchema(nil, for: harness.connection.id)
        PluginMetadataRegistry.shared.unregister(typeId: harness.typeId)
    }

    private func session(_ harness: Harness) -> ConnectionSession? {
        DatabaseManager.shared.session(for: harness.connection.id)
    }

    @Test("Switching database opens the new one and keeps the one left, without reconnecting")
    func switchKeepsTheConnectionLeft() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)

        let logs = try #require(harness.opener.opened["logs"])
        #expect(harness.opener.openCount == 1)
        #expect(session(harness)?.driver === logs)
        #expect(session(harness)?.status == .connected)
        #expect(session(harness)?.resolvedBrowseDatabase == "logs")
        #expect(session(harness)?.connection.database == "logs")
        #expect(harness.home.disconnectCallCount == 0)
        #expect(DatabaseManager.shared.sessionLanes.parkedDriver(for: harness.connection.id, database: "app") === harness.home)
    }

    @Test("Switching back reuses the connection the database already had")
    func switchingBackReusesTheConnection() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }

        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        try await DatabaseManager.shared.switchDatabase(to: "app", for: harness.connection.id, persist: false)

        let logs = try #require(harness.opener.opened["logs"])
        #expect(harness.opener.openCount == 1)
        #expect(session(harness)?.driver === harness.home)
        #expect(harness.home.disconnectCallCount == 0)
        #expect(logs.disconnectCallCount == 0)
        #expect(DatabaseManager.shared.sessionLanes.parkedDriver(for: harness.connection.id, database: "logs") === logs)
    }

    @Test("Switching back shows the catalog the database had, without emptying it on the way")
    func switchingBackKeepsTheCatalog() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let connectionId = harness.connection.id
        let tables = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        harness.home.tablesToReturn = tables
        await SchemaService.shared.reload(
            connectionId: connectionId,
            driver: harness.home,
            connection: harness.connection,
            scope: DatabaseScope(connectionId: connectionId, database: "app", schema: nil)
        )

        try await DatabaseManager.shared.switchDatabase(to: "logs", for: connectionId, persist: false)
        #expect(SchemaService.shared.state(for: connectionId) == .idle)
        try await DatabaseManager.shared.switchDatabase(to: "app", for: connectionId, persist: false)

        #expect(SchemaService.shared.state(for: connectionId) == .loaded(tables))
        await SchemaService.shared.invalidate(connectionId: connectionId)
    }

    @Test("A database the server refuses leaves the session where it was")
    func refusedOpenChangesNothing() async {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        harness.opener.failure = DatabaseError.connectionFailed("too many connections")

        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        }

        #expect(session(harness)?.driver === harness.home)
        #expect(session(harness)?.resolvedBrowseDatabase == "app")
        #expect(session(harness)?.connection.database == "app")
        #expect(DatabaseManager.shared.sessionLanes.parkedDatabases(for: harness.connection.id).isEmpty)
        #expect(harness.home.disconnectCallCount == 0)
    }

    @Test("Work on a database the user switched away from runs on that database's own connection")
    func workOnALeftDatabaseRunsOnItsConnection() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)

        let route = DatabaseManager.shared.executionRoute(for: scope)
        let ranOn = try await DatabaseManager.shared.withScopedDriver(
            scope: scope, route: route, cancellation: .untracked
        ) { driver in ObjectIdentifier(driver) }

        #expect(route == .sessionDriver)
        #expect(ranOn == ObjectIdentifier(harness.home))
    }

    @Test("Closing a database's entry closes its connection")
    func closingTheEntryClosesItsConnection() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)

        DatabaseManager.shared.sessionLanes.close(database: "app", for: harness.connection.id)

        #expect(harness.home.disconnectCallCount == 1)
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)
        #expect(DatabaseManager.shared.sessionLanes.parkedDriver(for: harness.connection.id, database: "app") == nil)
        #expect(DatabaseManager.shared.tableReadRoute(for: scope) == .pooled)
    }

    @Test("SQL on a database never browsed runs on a session connection of its own, which tracks its transaction")
    func userSQLOpensItsOwnSessionConnection() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "logs", schema: nil)

        let route = manager.executionRoute(for: scope)
        let ranOn = try await manager.withScopedDriver(
            scope: scope, route: route, cancellation: .untracked
        ) { driver -> ObjectIdentifier in
            (driver as? MockDatabaseDriver)?.sessionTransactionStateToReturn = .inTransaction
            return ObjectIdentifier(driver)
        }

        let logs = try #require(harness.opener.opened["logs"])
        #expect(route == .sessionDriver)
        #expect(ranOn == ObjectIdentifier(logs))
        #expect(manager.sessionLanes.parkedDriver(for: harness.connection.id, database: "logs") === logs)
        #expect(manager.sessionTransactions.holdsTransaction(connectionId: harness.connection.id, container: "logs"))
        #expect(session(harness)?.driver === harness.home)
        #expect(session(harness)?.resolvedBrowseDatabase == "app")

        let ranAgainOn = try await manager.withScopedDriver(
            scope: scope, route: manager.executionRoute(for: scope), cancellation: .untracked
        ) { driver in ObjectIdentifier(driver) }

        #expect(ranAgainOn == ObjectIdentifier(logs))
        #expect(harness.opener.openCount == 1)
        #expect(logs.disconnectCallCount == 0)
    }

    private func run(
        _ harness: Harness,
        on database: String,
        leaving state: PluginSessionTransactionState
    ) async throws -> ObjectIdentifier {
        let scope = DatabaseScope(connectionId: harness.connection.id, database: database, schema: nil)
        return try await DatabaseManager.shared.withScopedDriver(
            scope: scope, route: DatabaseManager.shared.executionRoute(for: scope), cancellation: .untracked
        ) { driver -> ObjectIdentifier in
            (driver as? MockDatabaseDriver)?.sessionTransactionStateToReturn = state
            return ObjectIdentifier(driver)
        }
    }

    @Test("A connection opened for SQL on a database never browsed is closed once idle, and reopened on the next use")
    func openedConnectionClosesWhenIdle() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        _ = try await run(harness, on: "logs", leaving: .idle)
        let logs = try #require(harness.opener.opened["logs"])

        await manager.closeIdleOpenedLanes(for: harness.connection.id)
        #expect(logs.disconnectCallCount == 0)

        await manager.closeIdleOpenedLanes(for: harness.connection.id, idleFor: 0)
        #expect(logs.disconnectCallCount == 1)
        #expect(manager.sessionLanes.parkedDriver(for: harness.connection.id, database: "logs") == nil)

        let reopenedOn = try await run(harness, on: "logs", leaving: .idle)
        #expect(harness.opener.openCount == 2)
        #expect(reopenedOn != ObjectIdentifier(logs))
    }

    @Test("An idle connection that holds a transaction, or cannot say, is never closed")
    func openedConnectionHoldingATransactionStays() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        _ = try await run(harness, on: "logs", leaving: .inTransaction)
        _ = try await run(harness, on: "audit", leaving: .unknown)

        await manager.closeIdleOpenedLanes(for: harness.connection.id, idleFor: 0)

        #expect(harness.opener.opened["logs"]?.disconnectCallCount == 0)
        #expect(harness.opener.opened["audit"]?.disconnectCallCount == 0)
        #expect(manager.sessionLanes.parkedDatabases(for: harness.connection.id).sorted() == ["audit", "logs"])
    }

    @Test("An opened connection holding session state the user set up is not closed for being idle")
    func openedLaneHoldingSessionStateIsNotClosedIdle() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let connectionId = harness.connection.id
        _ = try await run(harness, on: "logs", leaving: .idle)
        let logs = try #require(harness.opener.opened["logs"])
        let lane = SessionTransactionTracker.Key(connectionId: connectionId, lane: "logs")
        manager.sessionStateLedger.record(SQLSessionStateEffect(creates: .sessionSettings), on: logs, for: lane)

        await manager.closeIdleOpenedLanes(for: connectionId, idleFor: 0)

        #expect(logs.disconnectCallCount == 0)
        #expect(manager.sessionLanes.parkedDriver(for: connectionId, database: "logs") === logs)
        #expect(manager.sessionLanes.isOpened(database: "logs", for: connectionId))
    }

    @Test("The connection of a database the user browsed and left is not closed for being idle")
    func browsedConnectionIsNotClosedWhenIdle() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        harness.home.sessionTransactionStateToReturn = .idle
        try await manager.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        _ = try await run(harness, on: "app", leaving: .idle)

        await manager.closeIdleOpenedLanes(for: harness.connection.id, idleFor: 0)

        #expect(harness.home.disconnectCallCount == 0)
        #expect(manager.sessionLanes.parkedDriver(for: harness.connection.id, database: "app") === harness.home)
    }

    @Test("A switch that lands while the database's first statement holds a new connection browses on that connection")
    func switchAdoptsTheConnectionAStatementOpened() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let connectionId = harness.connection.id
        let hold = AsyncGate()
        harness.opener.holdsNextOpen = hold
        let switching = Task { @MainActor in
            try await manager.switchDatabase(to: "logs", for: connectionId, persist: false)
        }
        await hold.arrived(1)

        let ranOn = try await run(harness, on: "logs", leaving: .inTransaction)
        await hold.open()
        try await switching.value

        let switchOpened = try #require(harness.opener.inOrder.first)
        let statementOpened = try #require(harness.opener.inOrder.last)
        #expect(harness.opener.inOrder.count == 2)
        #expect(ranOn == ObjectIdentifier(statementOpened))
        #expect(session(harness)?.driver === statementOpened)
        #expect(statementOpened.disconnectCallCount == 0)
        #expect(switchOpened.disconnectCallCount == 1)
        #expect(manager.sessionTransactions.holdsTransaction(connectionId: connectionId, container: "logs"))
        #expect(manager.sessionLanes.parkedDriver(for: connectionId, database: "app") === harness.home)
    }

    @Test("A statement whose database became the browsed one while it opened a connection runs on the browsed one")
    func statementRunsOnTheConnectionASwitchInstalled() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let connectionId = harness.connection.id
        let hold = AsyncGate()
        harness.opener.holdsNextOpen = hold
        let statement = Task { @MainActor in
            try await self.run(harness, on: "logs", leaving: .idle)
        }
        await hold.arrived(1)

        try await manager.switchDatabase(to: "logs", for: connectionId, persist: false)
        await hold.open()
        let ranOn = try await statement.value

        let statementOpened = try #require(harness.opener.inOrder.first)
        let switchOpened = try #require(harness.opener.inOrder.last)
        #expect(ranOn == ObjectIdentifier(switchOpened))
        #expect(session(harness)?.driver === switchOpened)
        #expect(statementOpened.disconnectCallCount == 1)
        #expect(switchOpened.disconnectCallCount == 0)
    }

    @Test("A switch elsewhere on the connection while a statement opens its connection does not fail the statement")
    func unrelatedSwitchDoesNotFailTheStatement() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let hold = AsyncGate()
        harness.opener.holdsNextOpen = hold
        let statement = Task { @MainActor in
            try await self.run(harness, on: "logs", leaving: .idle)
        }
        await hold.arrived(1)

        _ = manager.sessionLanes.beginSwitch(for: harness.connection.id)
        await hold.open()
        let ranOn = try await statement.value

        let superseded = try #require(harness.opener.inOrder.first)
        let parked = try #require(manager.sessionLanes.parkedDriver(for: harness.connection.id, database: "logs"))
        #expect(harness.opener.openCount == 2)
        #expect(superseded.disconnectCallCount == 1)
        #expect(ranOn == ObjectIdentifier(parked))
    }

    @Test("A server that refuses the session connection fails the statement and parks nothing")
    func refusedSessionConnectionFailsTheStatement() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        harness.opener.failure = DatabaseError.connectionFailed("too many connections")
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "logs", schema: nil)

        await #expect(throws: DatabaseError.self) {
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope, route: .sessionDriver, cancellation: .untracked
            ) { _ in () }
        }

        #expect(DatabaseManager.shared.sessionLanes.parkedDatabases(for: harness.connection.id).isEmpty)
    }

    @Test("A statement queued for a connection that is gone by its turn is refused, not moved onto a new one")
    func statementQueuedForAGoneConnectionIsRefused() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        try await manager.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)
        let key = SessionDriverGate.Key(connectionId: harness.connection.id, database: "app")
        let acquired = AsyncGate()
        let release = AsyncGate()
        let holder = Task { @MainActor in
            try await manager.sessionDriverGate.withExclusiveAccess(key) {
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()
        let queued = Task { @MainActor in
            try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .untracked) { _ in () }
        }
        try await waitUntil { manager.sessionDriverGate.waiterCount(for: harness.connection.id) >= 1 }

        manager.sessionLanes.close(database: "app", for: harness.connection.id)
        await release.open()
        try await holder.value

        await #expect(throws: (any Error).self) { try await queued.value }
        #expect(harness.opener.opened["app"] == nil)
    }

    @Test("Ending the session closes every database's connection")
    func endingTheSessionClosesThemAll() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)

        DatabaseManager.shared.removeSession(for: harness.connection.id)

        #expect(harness.home.disconnectCallCount == 1)
        #expect(DatabaseManager.shared.sessionLanes.parkedDatabases(for: harness.connection.id).isEmpty)
    }

    /// A ping that failed on the connection left behind must not reconnect the one the user moved
    /// onto, which would take its transaction with it.
    @Test("A reconnect for a failed check leaves a connection that replaced the checked one alone")
    func reconnectIsFencedOnTheCheckedDriver() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        let logs = try #require(harness.opener.opened["logs"])

        let outcome = await DatabaseManager.shared.performHealthMonitorReconnect(
            connectionId: harness.connection.id,
            failedDriver: ObjectIdentifier(harness.home)
        )

        #expect(outcome == .success)
        #expect(session(harness)?.driver === logs)
        #expect(logs.disconnectCallCount == 0)
    }

    @Test("A parked connection that died holding a transaction is replaced and the work refused once")
    func deadParkedTransactionIsReported() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        harness.home.pingError = DatabaseError.connectionFailed("server closed the connection")
        harness.home.sessionTransactionStateToReturn = .inTransaction
        harness.home.pingFailureForgetsTransactionState = true
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)

        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope, route: .sessionDriver, cancellation: .untracked
            ) { _ in () }
        }

        let replacement = try #require(harness.opener.opened["app"])
        #expect(harness.home.disconnectCallCount == 1)
        #expect(DatabaseManager.shared.sessionLanes.parkedDriver(for: harness.connection.id, database: "app") === replacement)
        let ranOn = try await DatabaseManager.shared.withScopedDriver(
            scope: scope, route: .sessionDriver, cancellation: .untracked
        ) { driver in ObjectIdentifier(driver) }
        #expect(ranOn == ObjectIdentifier(replacement))
    }

    @Test("A parked connection that died idle is replaced without failing the work")
    func deadIdleParkedConnectionIsReplacedQuietly() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        harness.home.pingError = DatabaseError.connectionFailed("server closed the connection")
        harness.home.sessionTransactionStateToReturn = .idle
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)

        let ranOn = try await DatabaseManager.shared.withScopedDriver(
            scope: scope, route: .sessionDriver, cancellation: .untracked
        ) { driver in ObjectIdentifier(driver) }

        let replacement = try #require(harness.opener.opened["app"])
        #expect(ranOn == ObjectIdentifier(replacement))
    }

    /// Coming back to a database is a promotion, not a turn, so it has to make the same check: a
    /// parked connection that died holding a transaction is replaced, and the next work is refused once.
    @Test("Switching back to a database whose connection died holding a transaction reports it once")
    func switchingBackToADeadTransactionReportsIt() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        harness.home.pingError = DatabaseError.connectionFailed("server closed the connection")
        harness.home.sessionTransactionStateToReturn = .inTransaction
        harness.home.pingFailureForgetsTransactionState = true

        try await DatabaseManager.shared.switchDatabase(to: "app", for: harness.connection.id, persist: false)

        let replacement = try #require(harness.opener.opened["app"])
        #expect(session(harness)?.driver === replacement)
        #expect(harness.home.disconnectCallCount == 1)
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)
        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope, route: .sessionDriver, cancellation: .untracked
            ) { _ in () }
        }
        let ranOn = try await DatabaseManager.shared.withScopedDriver(
            scope: scope, route: .sessionDriver, cancellation: .untracked
        ) { driver in ObjectIdentifier(driver) }
        #expect(ranOn == ObjectIdentifier(replacement))
    }

    /// A check that is still pinging holds the database's turn, which is no proof the connection
    /// answers, so a switch back waits for the check and takes what it settles on.
    @Test("Switching back while a check of the parked connection runs promotes what the check settles on")
    func switchingBackWaitsForARunningCheck() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        harness.home.pingError = DatabaseError.connectionFailed("server closed the connection")
        harness.home.sessionTransactionStateToReturn = .idle
        let ping = AsyncGate()
        harness.home.pingGate = ping
        let lanes = DatabaseManager.shared.sessionLanes
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)
        let connectionId = harness.connection.id
        let work = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope, route: .sessionDriver, cancellation: .untracked
            ) { driver in ObjectIdentifier(driver) }
        }
        try await waitUntil { lanes.isVerifying(harness.home) }
        #expect(lanes.isVerifying(harness.home))

        let generation = lanes.generation(for: connectionId)
        let switchBack = Task { @MainActor in
            try await DatabaseManager.shared.switchDatabase(to: "app", for: connectionId, persist: false)
        }
        // The switch takes its generation and then waits for the check, with no suspension between.
        try await waitUntil { lanes.generation(for: connectionId) != generation }
        await ping.open()
        try await switchBack.value

        let replacement = try #require(harness.opener.opened["app"])
        #expect(session(harness)?.driver === replacement)
        #expect(session(harness)?.status == .connected)
        #expect(harness.home.disconnectCallCount == 1)
        #expect(harness.opener.openCount == 2)
        #expect(try await work.value == ObjectIdentifier(replacement))
    }

    @Test("A switch while the connection is being rebuilt promotes nothing")
    func switchWaitsForATransportRebuild() async {
        let harness = makeHarness()
        defer {
            MetadataConnectionPool.shared.endTransportReplacement(connectionId: harness.connection.id)
            cleanUp(harness)
        }
        MetadataConnectionPool.shared.beginTransportReplacement(connectionId: harness.connection.id)

        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        }

        #expect(harness.opener.openCount == 0)
        #expect(session(harness)?.driver === harness.home)
    }

    /// A schema switch moves the browsed connection's search path, so it has to take the same turn
    /// as work on that database, or it lands between a statement's pin and the statement.
    @Test("A schema switch waits for work running on the browsed database's connection")
    func schemaSwitchSharesTheDatabaseTurn() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let release = AsyncGate()
        let acquired = AsyncGate()
        let holder = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(
                SessionDriverGate.Key(connectionId: harness.connection.id, database: "app")
            ) {
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let schemaSwitch = Task { @MainActor in
            try await DatabaseManager.shared.switchSchema(to: "reporting", for: harness.connection.id)
        }
        try await waitUntil {
            DatabaseManager.shared.sessionDriverGate.waiterCount(for: harness.connection.id) >= 1
        }

        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: harness.connection.id) == 1)
        #expect(harness.home.switchSchemaCallCount == 0)
        await release.open()
        try await holder.value
        try await schemaSwitch.value
        #expect(harness.home.switchSchemaCallCount == 1)
    }

    @Test("A rebuilt transport reports each parked transaction it ended, once")
    func transportRebuildReportsParkedTransactions() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        harness.home.sessionTransactionStateToReturn = .inTransaction
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)

        await DatabaseManager.shared.sessionLanes.closeAllNotingLosses(for: harness.connection.id)

        #expect(harness.home.disconnectCallCount == 1)
        #expect(DatabaseManager.shared.executionRoute(for: scope) == .sessionDriver)
        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.executionRoute(for: scope),
                cancellation: .untracked
            ) { _ in () }
        }
        #expect(!DatabaseManager.shared.sessionLanes.hasLoss(database: "app", for: harness.connection.id))
    }

    @Test("A rebuilt transport reports what the user's statements set up on a parked connection, once")
    func transportRebuildReportsALanesSessionState() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let connectionId = harness.connection.id
        try await manager.switchDatabase(to: "logs", for: connectionId, persist: false)
        harness.home.sessionTransactionStateToReturn = .idle
        let lane = SessionTransactionTracker.Key(connectionId: connectionId, lane: "app")
        manager.sessionStateLedger.record(SQLSessionStateEffect(creates: .temporaryObjects), on: harness.home, for: lane)
        let scope = DatabaseScope(connectionId: connectionId, database: "app", schema: nil)

        await manager.closeTransportLanes(for: connectionId) { true }

        #expect(harness.home.disconnectCallCount == 1)
        #expect(manager.executionRoute(for: scope) == .sessionDriver)
        let error = await #expect(throws: DatabaseError.self) {
            try await manager.withScopedDriver(
                scope: scope, route: manager.executionRoute(for: scope), cancellation: .untracked
            ) { _ in () }
        }
        let expected = DatabaseManager.sessionLostMessage(
            database: "app", loss: SessionLoss(transaction: false, state: .temporaryObjects)
        )
        #expect(error?.localizedDescription.contains(expected) == true)
        #expect(!manager.sessionLanes.hasLoss(database: "app", for: connectionId))
    }

    @Test("A parked connection that died holding session state the user set up is replaced and the work refused once")
    func deadParkedLaneReportsItsSessionState() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let connectionId = harness.connection.id
        try await manager.switchDatabase(to: "logs", for: connectionId, persist: false)
        harness.home.pingError = DatabaseError.connectionFailed("server closed the connection")
        harness.home.sessionTransactionStateToReturn = .idle
        let lane = SessionTransactionTracker.Key(connectionId: connectionId, lane: "app")
        manager.sessionStateLedger.record(SQLSessionStateEffect(creates: .userVariables), on: harness.home, for: lane)
        let scope = DatabaseScope(connectionId: connectionId, database: "app", schema: nil)

        let error = await #expect(throws: DatabaseError.self) {
            try await manager.withScopedDriver(
                scope: scope, route: .sessionDriver, cancellation: .untracked
            ) { _ in () }
        }

        let expected = DatabaseManager.sessionLostMessage(
            database: "app", loss: SessionLoss(transaction: false, state: .userVariables)
        )
        #expect(error?.localizedDescription.contains(expected) == true)
        let replacement = try #require(harness.opener.opened["app"])
        #expect(harness.home.disconnectCallCount == 1)
        let ranOn = try await manager.withScopedDriver(
            scope: scope, route: .sessionDriver, cancellation: .untracked
        ) { driver in ObjectIdentifier(driver) }
        #expect(ranOn == ObjectIdentifier(replacement))
    }

    @Test("A grid save on a database whose lane died with session state is refused once, and the next one runs")
    func firstOwningTurnOnALostLaneTakesTheReport() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        let connectionId = harness.connection.id
        try await manager.switchDatabase(to: "logs", for: connectionId, persist: false)
        harness.home.sessionTransactionStateToReturn = .idle
        let lane = SessionTransactionTracker.Key(connectionId: connectionId, lane: "app")
        manager.sessionStateLedger.record(SQLSessionStateEffect(creates: .temporaryObjects), on: harness.home, for: lane)
        await manager.closeTransportLanes(for: connectionId) { true }
        let scope = DatabaseScope(connectionId: connectionId, database: "app", schema: nil)

        let error = await #expect(throws: DatabaseError.self) {
            try await manager.withScopedDriver(
                scope: scope, route: manager.executionRoute(for: scope), cancellation: .protectedWrite
            ) { _ in () }
        }

        let expected = DatabaseManager.sessionLostMessage(
            database: "app", loss: SessionLoss(transaction: false, state: .temporaryObjects)
        )
        #expect(error?.localizedDescription.contains(expected) == true)
        #expect(harness.opener.opened["app"] == nil)
        #expect(!manager.sessionLanes.hasLoss(database: "app", for: connectionId))
        let savedOn = try await manager.withScopedDriver(
            scope: scope, route: manager.executionRoute(for: scope), cancellation: .protectedWrite
        ) { driver in ObjectIdentifier(driver) }
        let reopened = try #require(harness.opener.opened["app"])
        #expect(savedOn == ObjectIdentifier(reopened))
    }

    @Test("A run notes what ran: every statement, through the one that failed, or only those a Stop let run")
    func ranCountFollowsTheOutcome() {
        let completed = BatchStatementOutcome<Int>.completed(results: [1, 2, 3])
        let stopped = BatchStatementOutcome<Int>.cancelled(results: [1])
        let failed = BatchStatementOutcome<Int>.failed(
            results: [1], failure: .statement(sql: "SET x = 1"), errorDescription: "failed"
        )
        #expect(completed.ranCount(of: 3) == 3)
        #expect(stopped.ranCount(of: 3) == 1)
        #expect(failed.ranCount(of: 3) == 2)
    }

    @Test("A table read leaves a lost transaction's report for the user's next statement")
    func tableReadLeavesTheLossReport() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let manager = DatabaseManager.shared
        manager.sessionLanes.markLost(database: "app", transaction: true, for: harness.connection.id)
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)

        let ranOn = try await manager.withTableReadDriver(scope: scope, cancellation: .untracked) { driver in
            ObjectIdentifier(driver)
        }

        #expect(ranOn == ObjectIdentifier(harness.home))
        #expect(manager.sessionLanes.hasLoss(database: "app", for: harness.connection.id))
        await #expect(throws: DatabaseError.self) {
            try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .untracked) { _ in () }
        }
    }

    @Test("Closing a database supersedes a reopen of it still in flight")
    func closingSupersedesAReopen() {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let lanes = DatabaseManager.shared.sessionLanes
        let before = lanes.generation(for: harness.connection.id)

        lanes.close(database: "app", for: harness.connection.id)

        #expect(!lanes.isCurrent(before, for: harness.connection.id))
    }

    @Test("A driver that reported its connection lost is not trusted on a recent check")
    func lostConnectionIsNotFresh() {
        let driver = MockDatabaseDriver()
        let lanes = SessionLanes(opener: { _ in driver })
        lanes.markVerified(driver)
        #expect(lanes.isFresh(driver))

        driver.hasLostConnection = true

        #expect(!lanes.isFresh(driver))
    }

    @Test("Switching database saves the schema of the database switched to")
    func switchSavesTheTargetSchema() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        AppSettingsStorage.shared.saveLastSchema("app_schema", for: harness.connection.id)
        harness.opener.schemaForNextOpen = "logs_schema"

        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)

        #expect(AppSettingsStorage.shared.loadLastSchema(for: harness.connection.id) == "logs_schema")
    }

    @Test("An open transaction is reported for the browsed database and for every parked one")
    func openTransactionsAreReportedOnEveryLane() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        let logs = try #require(harness.opener.opened["logs"])
        harness.home.sessionTransactionStateToReturn = .inTransaction
        logs.sessionTransactionStateToReturn = .abortedTransaction

        let holding = await DatabaseManager.shared.databasesHoldingTransaction(for: harness.connection.id)
        let parkedOnly = await DatabaseManager.shared.databasesHoldingTransaction(
            for: harness.connection.id,
            among: ["app"]
        )

        #expect(holding.sorted() == ["app", "logs"])
        #expect(parkedOnly == ["app"])
    }

    /// A lock or an unknown state loses no work, so neither is worth asking about.
    @Test(
        "A connection without an open transaction is not reported",
        arguments: [PluginSessionTransactionState.idle, .holdsSessionLocks, .unknown]
    )
    func onlyAnOpenTransactionIsReported(_ state: PluginSessionTransactionState) async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        try await DatabaseManager.shared.switchDatabase(to: "logs", for: harness.connection.id, persist: false)
        let logs = try #require(harness.opener.opened["logs"])
        harness.home.sessionTransactionStateToReturn = state
        logs.sessionTransactionStateToReturn = state

        let holding = await DatabaseManager.shared.databasesHoldingTransaction(for: harness.connection.id)

        #expect(holding.isEmpty)
    }

    @Test("A connection running a turn is not asked, because asking would wait for the turn")
    func connectionRunningATurnIsSkipped() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        harness.home.sessionTransactionStateToReturn = .inTransaction
        let release = AsyncGate()
        let acquired = AsyncGate()
        let holder = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(
                SessionDriverGate.Key(connectionId: harness.connection.id, database: "app")
            ) {
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let holding = await DatabaseManager.shared.databasesHoldingTransaction(for: harness.connection.id)

        await release.open()
        try await holder.value
        #expect(holding.isEmpty)
    }

    @Test("A connection that does not answer counts as holding nothing once the bound passes")
    func silentConnectionIsBounded() async {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        harness.home.sessionTransactionStateToReturn = .inTransaction
        let reply = AsyncGate()
        harness.home.sessionTransactionStateGate = reply
        let clock = ManualClock()
        let connectionId = harness.connection.id
        let probe = Task { @MainActor in
            await DatabaseManager.shared.databasesHoldingTransaction(for: connectionId, clock: clock)
        }

        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))
        let holding = await probe.value

        #expect(holding.isEmpty)
        #expect(harness.home.finishedSessionTransactionStateReads == 0)
        await reply.open()
    }

    /// A driver's cancel can reach past the read: FreeTDS stops every call queued on the connection.
    @Test("A read that misses the bound is left to finish, not cancelled")
    func lateReadIsNotCancelled() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        harness.home.sessionTransactionStateToReturn = .inTransaction
        let reply = AsyncGate()
        harness.home.sessionTransactionStateGate = reply
        let clock = ManualClock()
        let connectionId = harness.connection.id
        let probe = Task { @MainActor in
            await DatabaseManager.shared.databasesHoldingTransaction(for: connectionId, clock: clock)
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))
        let holding = await probe.value

        await reply.open()
        try await waitUntil { harness.home.finishedSessionTransactionStateReads == 1 }

        #expect(holding.isEmpty)
        #expect(!harness.home.sessionTransactionStateReadWasCancelled)
    }
}
