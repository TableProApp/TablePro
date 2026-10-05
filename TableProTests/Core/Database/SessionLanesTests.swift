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
import Testing

@Suite("Session lanes", .serialized)
@MainActor
struct SessionLanesTests {
    /// Reopens its connection to change database and can open a second one, like PostgreSQL.
    private static let typeId = "SessionLaneFake"

    private final class Opener {
        var opened: [String: MockDatabaseDriver] = [:]
        var openCount = 0
        var failure: Error?
        var schemaForNextOpen: String?

        func open(_ scope: DatabaseScope) async throws -> DatabaseDriver {
            openCount += 1
            if let failure { throw failure }
            let driver = MockDatabaseDriver()
            driver.currentSchema = schemaForNextOpen
            opened[scope.database] = driver
            return driver
        }
    }

    private struct Harness {
        let connection: DatabaseConnection
        let home: MockDatabaseDriver
        let opener: Opener
    }

    private func registerTypeIfNeeded() {
        guard PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: Self.typeId) == nil else { return }
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
            displayName: Self.typeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "sessionlanefake", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["sessionlanefake"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: capabilities, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: Self.typeId)
    }

    /// A connected session browsing `app` on `home`, with lane opens answered by `opener`.
    private func makeHarness() -> Harness {
        registerTypeIfNeeded()
        var connection = TestFixtures.makeConnection(database: "app")
        connection.type = DatabaseType(rawValue: Self.typeId)
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
        return Harness(connection: connection, home: home, opener: opener)
    }

    private func cleanUp(_ harness: Harness) {
        DatabaseManager.shared.removeSession(for: harness.connection.id)
        DatabaseManager.shared.sessionLanes.opener = { scope in
            try await MetadataConnectionPool.openServerDriver(for: scope, purpose: .session)
        }
        AppSettingsStorage.shared.saveLastDatabase(nil, for: harness.connection.id)
        AppSettingsStorage.shared.saveLastSchema(nil, for: harness.connection.id)
        PluginMetadataRegistry.shared.unregister(typeId: Self.typeId)
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
        #expect(DatabaseManager.shared.executionRoute(for: scope) == .pooled)
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
        harness.home.pingDelaySeconds = 1
        let lanes = DatabaseManager.shared.sessionLanes
        let scope = DatabaseScope(connectionId: harness.connection.id, database: "app", schema: nil)
        let work = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope, route: .sessionDriver, cancellation: .untracked
            ) { driver in ObjectIdentifier(driver) }
        }
        let deadline = Date().addingTimeInterval(5)
        while !lanes.isVerifying(harness.home), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lanes.isVerifying(harness.home))

        try await DatabaseManager.shared.switchDatabase(to: "app", for: harness.connection.id, persist: false)

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
        let release = AsyncLatch()
        let acquired = AsyncLatch()
        let holder = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(
                SessionDriverGate.Key(connectionId: harness.connection.id, database: "app")
            ) {
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let schemaSwitch = Task { @MainActor in
            try await DatabaseManager.shared.switchSchema(to: "reporting", for: harness.connection.id)
        }
        for _ in 0..<10_000 where DatabaseManager.shared.sessionDriverGate.waiterCount(for: harness.connection.id) < 1 {
            await Task.yield()
        }

        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: harness.connection.id) == 1)
        #expect(harness.home.switchSchemaCallCount == 0)
        release.open()
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

        await DatabaseManager.shared.sessionLanes.closeAllNotingLostTransactions(for: harness.connection.id)

        #expect(harness.home.disconnectCallCount == 1)
        #expect(DatabaseManager.shared.executionRoute(for: scope) == .sessionDriver)
        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.executionRoute(for: scope),
                cancellation: .untracked
            ) { _ in () }
        }
        #expect(DatabaseManager.shared.executionRoute(for: scope) == .pooled)
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
}

@MainActor
private final class AsyncLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
