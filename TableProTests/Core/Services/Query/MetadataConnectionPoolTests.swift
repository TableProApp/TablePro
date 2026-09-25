//
//  MetadataConnectionPoolTests.swift
//  TableProTests
//
//  Tests for the pool's bounded connect and schema-switch steps: a hanging
//  driver must fail within the deadline instead of stalling the pool entry.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct MetadataConnectionPoolTests {
    @Test("connect passes through when the driver responds in time")
    func connectPassesThrough() async throws {
        let driver = MockDatabaseDriver()

        try await MetadataConnectionPool.connect(driver, database: "db", timeoutSeconds: 1)
    }

    @Test("connect fails with a connection error when the driver hangs")
    func connectTimesOut() async {
        let driver = MockDatabaseDriver()
        driver.connectDelaySeconds = 5

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.connect(driver, database: "db", timeoutSeconds: 0.05)
        }
    }

    @Test("connect force-disconnects a driver that ignores cancellation")
    func connectUnsticksCancellationDeafDriver() async {
        let driver = MockDatabaseDriver()
        driver.hangsUntilDisconnect = true

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.connect(driver, database: "db", timeoutSeconds: 0.05)
        }
    }

    @Test("schema switch passes through when the driver responds in time")
    func switchSchemaPassesThrough() async throws {
        let driver = MockDatabaseDriver()

        try await MetadataConnectionPool.switchSchema(driver, to: "HR", timeoutSeconds: 1)

        #expect(driver.currentSchema == "HR")
    }

    @Test("schema switch fails with a connection error when the driver hangs")
    func switchSchemaTimesOut() async {
        let driver = MockDatabaseDriver()
        driver.switchSchemaDelaySeconds = 5

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.switchSchema(driver, to: "HR", timeoutSeconds: 0.05)
        }
        #expect(driver.currentSchema == nil)
    }

    @Test("schema switch is skipped when the driver already reports that schema")
    func switchSchemaSkipsRedundantStatement() async throws {
        let driver = MockDatabaseDriver()
        driver.currentSchema = "APP_SCHEMA"

        try await MetadataConnectionPool.switchSchema(driver, to: "APP_SCHEMA", timeoutSeconds: 1)

        #expect(driver.switchSchemaCallCount == 0)
    }

    @Test("schema switch still runs when the driver is on another schema")
    func switchSchemaRunsWhenSchemaDiffers() async throws {
        let driver = MockDatabaseDriver()
        driver.currentSchema = "HR"

        try await MetadataConnectionPool.switchSchema(driver, to: "APP_SCHEMA", timeoutSeconds: 1)

        #expect(driver.switchSchemaCallCount == 1)
        #expect(driver.currentSchema == "APP_SCHEMA")
    }

    @Test("a redundant schema switch cannot time out on a hanging driver")
    func switchSchemaSkipsBeforeItCanHang() async throws {
        let driver = MockDatabaseDriver()
        driver.currentSchema = "APP_SCHEMA"
        driver.switchSchemaDelaySeconds = 5

        try await MetadataConnectionPool.switchSchema(driver, to: "APP_SCHEMA", timeoutSeconds: 0.05)

        #expect(driver.switchSchemaCallCount == 0)
    }

    @Test("session preparation fails with a connection error when a startup command hangs")
    func prepareSessionTimesOut() async {
        let driver = MockDatabaseDriver()
        driver.executeDelaySeconds = 5

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.prepareSession(
                driver,
                queryTimeoutSeconds: 0,
                startupCommands: "SELECT pg_advisory_lock(42)",
                connectionName: "test",
                timeoutSeconds: 0.05
            )
        }
    }

    @Test("session preparation applies the query timeout and passes through")
    func prepareSessionPassesThrough() async throws {
        let driver = MockDatabaseDriver()

        try await MetadataConnectionPool.prepareSession(
            driver,
            queryTimeoutSeconds: 30,
            startupCommands: nil,
            connectionName: "test",
            timeoutSeconds: 1
        )

        #expect(driver.applyQueryTimeoutValues == [30])
    }

    @Test("database switch rejects a driver that cannot switch")
    func switchDatabaseRejectsUnsupportedDriver() async {
        let driver = MockDatabaseDriver()

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.switchDatabase(driver, to: "shop", timeoutSeconds: 1)
        }
    }

    @Test("withDriver refuses a scope whose connection has no live session")
    func withDriverRequiresALiveSession() async throws {
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)
        let ranBody = PoolBodyFlag()

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.shared.withDriver(scope: scope) { _ in
                ranBody.value = true
            }
        }

        #expect(!ranBody.value)
    }
}

private final class PoolBodyFlag: @unchecked Sendable {
    var value = false
}

/// Stands in for opening a pooled connection. Each open takes the next connect delay, and a delayed
/// connect throws when its open is cancelled, the way libpq's cooperative connect does.
@MainActor
private final class RecordingOpener {
    private var connectDelays: [Double]
    private(set) var opened: [MockDatabaseDriver] = []

    init(connectDelays: [Double] = []) {
        self.connectDelays = connectDelays
    }

    func open(_ scope: DatabaseScope) async throws -> DatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.connectDelaySeconds = connectDelays.isEmpty ? 0 : connectDelays.removeFirst()
        opened.append(driver)
        try await driver.connect()
        return driver
    }
}

/// A reconnect that rebuilds a connection's transport used to close every pooled entry and cancel
/// every open in progress, so a table load dialing a pooled connection failed as a user cancel and
/// showed nothing.
@Suite("MetadataConnectionPool transport replacement", .serialized)
@MainActor
struct MetadataConnectionPoolTransportReplacementTests {
    private func makeSession() -> (DatabaseConnection, DatabaseScope) {
        let connection = TestFixtures.makeConnection(database: "shop")
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, DatabaseScope(connectionId: connection.id, database: "shop", schema: nil))
    }

    /// Bounded, so a caller that never reaches the point being waited for fails the assertions after
    /// it rather than hanging the suite.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A lease waiting on an open the replacement withdrew takes a new connection once it ends")
    func withdrawnOpenIsRetriedAfterTheReplacement() async throws {
        let (connection, scope) = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = RecordingOpener(connectDelays: [5, 0])
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let lease = Task { @MainActor in
            try await pool.withDriver(scope: scope) { driver in ObjectIdentifier(driver) }
        }
        await waitUntil { opener.opened.count == 1 }
        #expect(opener.opened.count == 1)

        pool.beginTransportReplacement(connectionId: connection.id)
        await waitUntil { pool.transportWaiterCount(for: connection.id) == 1 }
        #expect(pool.transportWaiterCount(for: connection.id) == 1)
        #expect(opener.opened.count == 1)

        pool.endTransportReplacement(connectionId: connection.id)
        let ranOn = try await lease.value

        #expect(opener.opened.count == 2)
        #expect(ranOn == opener.opened.last.map { ObjectIdentifier($0) })
    }

    /// A new open during the replacement would read the effective connection before the reconnect
    /// replaced it, and dial a tunnel port that is about to close.
    @Test("A lease that arrives during a replacement opens nothing until it ends")
    func leaseDuringAReplacementWaitsToOpen() async throws {
        let (connection, scope) = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = RecordingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        pool.beginTransportReplacement(connectionId: connection.id)
        let lease = Task { @MainActor in
            try await pool.withDriver(scope: scope) { _ in }
        }
        await waitUntil { pool.transportWaiterCount(for: connection.id) == 1 }
        #expect(pool.transportWaiterCount(for: connection.id) == 1)
        #expect(opener.opened.isEmpty)

        pool.endTransportReplacement(connectionId: connection.id)
        try await lease.value

        #expect(opener.opened.count == 1)
    }

    @Test("Overlapping replacements hold pooled work until the last one ends")
    func overlappingReplacementsHoldUntilTheLastEnds() async throws {
        let (connection, scope) = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = RecordingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        pool.beginTransportReplacement(connectionId: connection.id)
        pool.beginTransportReplacement(connectionId: connection.id)
        let lease = Task { @MainActor in
            try await pool.withDriver(scope: scope) { _ in }
        }
        await waitUntil { pool.transportWaiterCount(for: connection.id) == 1 }

        pool.endTransportReplacement(connectionId: connection.id)
        #expect(pool.transportWaiterCount(for: connection.id) == 1)
        #expect(opener.opened.isEmpty)

        pool.endTransportReplacement(connectionId: connection.id)
        try await lease.value

        #expect(opener.opened.count == 1)
        #expect(!pool.isReplacingTransport(for: connection.id))
    }

    @Test("A lease cancelled while it waits for a replacement stops waiting at once")
    func cancelledWaiterStopsWaiting() async throws {
        let (connection, scope) = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = RecordingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        pool.beginTransportReplacement(connectionId: connection.id)
        defer { pool.endTransportReplacement(connectionId: connection.id) }
        let lease = Task { @MainActor in
            try await pool.withDriver(scope: scope) { _ in }
        }
        await waitUntil { pool.transportWaiterCount(for: connection.id) == 1 }
        #expect(pool.transportWaiterCount(for: connection.id) == 1)

        lease.cancel()

        await #expect(throws: CancellationError.self) {
            try await lease.value
        }
        #expect(pool.transportWaiterCount(for: connection.id) == 0)
        #expect(opener.opened.isEmpty)
    }

    /// A rename needs every backend on the database gone, and PostgreSQL refuses it while one is
    /// attached, so an open withdrawn for it must never be dialed again.
    @Test("Closing a database withdraws its open for good and fails the lease waiting on it")
    func closingADatabaseFailsItsWaiter() async throws {
        let (connection, scope) = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = RecordingOpener(connectDelays: [5])
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let lease = Task { @MainActor in
            try await pool.withDriver(scope: scope) { _ in }
        }
        await waitUntil { opener.opened.count == 1 }
        #expect(opener.opened.count == 1)

        pool.closeAll(connectionId: connection.id, database: "shop")

        await #expect(throws: (any Error).self) {
            try await lease.value
        }
        #expect(opener.opened.count == 1)
    }

    /// Ordered so that a parked lease the close failed to reach opens a connection once the
    /// replacement ends, and fails the expectations, rather than hanging the suite.
    @Test("Closing a connection fails the leases parked for its replacement at once")
    func closingAConnectionFailsParkedLeases() async throws {
        let (connection, scope) = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = RecordingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        pool.beginTransportReplacement(connectionId: connection.id)
        let lease = Task { @MainActor in
            try await pool.withDriver(scope: scope) { _ in }
        }
        await waitUntil { pool.transportWaiterCount(for: connection.id) == 1 }
        #expect(pool.transportWaiterCount(for: connection.id) == 1)

        pool.closeAll(connectionId: connection.id)
        #expect(pool.transportWaiterCount(for: connection.id) == 0)
        pool.endTransportReplacement(connectionId: connection.id)

        await #expect(throws: CancellationError.self) {
            try await lease.value
        }
        #expect(opener.opened.isEmpty)
    }

    @Test("Closing one database fails only the leases parked for that database")
    func closingADatabaseFailsOnlyItsParkedLeases() async throws {
        let (connection, shop) = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let reports = DatabaseScope(connectionId: connection.id, database: "reports", schema: nil)
        let opener = RecordingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        pool.beginTransportReplacement(connectionId: connection.id)
        let shopLease = Task { @MainActor in
            try await pool.withDriver(scope: shop) { _ in }
        }
        let reportsLease = Task { @MainActor in
            try await pool.withDriver(scope: reports) { _ in }
        }
        await waitUntil { pool.transportWaiterCount(for: connection.id) == 2 }
        #expect(pool.transportWaiterCount(for: connection.id) == 2)

        pool.closeAll(connectionId: connection.id, database: "shop")
        #expect(pool.transportWaiterCount(for: connection.id) == 1)
        pool.endTransportReplacement(connectionId: connection.id)

        await #expect(throws: CancellationError.self) {
            try await shopLease.value
        }
        try await reportsLease.value
        #expect(opener.opened.count == 1)
    }
}

@Suite("MetadataConnectionPool idle eviction", .serialized)
@MainActor
struct MetadataConnectionPoolIdleEvictionTests {
    private func scope(_ connectionId: UUID, database: String) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: nil)
    }

    @Test("an entry nobody has used for the idle timeout is closed and dropped")
    func sweepClosesIdleEntries() {
        let connectionId = UUID()
        let driver = MockDatabaseDriver()
        let pool = MetadataConnectionPool.isolatedForTesting()
        defer { pool.closeAll(connectionId: connectionId) }

        pool.injectEntry(driver, scope: scope(connectionId, database: "shop"))
        pool.sweepIdleEntries(now: Date().addingTimeInterval(MetadataConnectionPool.idleTimeout + 1))

        #expect(pool.pooledDriverCount(for: connectionId) == 0)
        #expect(driver.disconnectCallCount == 1)
    }

    @Test("an entry used inside the idle timeout is left alone")
    func sweepSparesRecentEntries() {
        let connectionId = UUID()
        let driver = MockDatabaseDriver()
        let pool = MetadataConnectionPool.isolatedForTesting()
        defer { pool.closeAll(connectionId: connectionId) }

        pool.injectEntry(driver, scope: scope(connectionId, database: "shop"))
        pool.sweepIdleEntries(now: Date().addingTimeInterval(MetadataConnectionPool.idleTimeout - 1))

        #expect(pool.pooledDriverCount(for: connectionId) == 1)
        #expect(driver.disconnectCallCount == 0)
    }

    @Test("an entry with work on it survives the sweep however old it looks")
    func sweepSparesEntriesWithWorkInFlight() {
        let connectionId = UUID()
        let driver = MockDatabaseDriver()
        let pool = MetadataConnectionPool.isolatedForTesting()
        defer { pool.closeAll(connectionId: connectionId) }

        pool.injectEntry(driver, scope: scope(connectionId, database: "shop"))
        pool.markInFlight(scope: scope(connectionId, database: "shop"))
        pool.sweepIdleEntries(now: Date().addingTimeInterval(MetadataConnectionPool.idleTimeout * 10))

        #expect(pool.pooledDriverCount(for: connectionId) == 1)
        #expect(driver.disconnectCallCount == 0)
    }

    @Test("only the idle entries go, not every entry the connection holds")
    func sweepIsPerEntryNotPerConnection() {
        let connectionId = UUID()
        let stale = MockDatabaseDriver()
        let fresh = MockDatabaseDriver()
        let pool = MetadataConnectionPool.isolatedForTesting()
        defer { pool.closeAll(connectionId: connectionId) }

        let now = Date()
        pool.injectEntry(
            stale,
            scope: scope(connectionId, database: "shop"),
            lastUsed: now.addingTimeInterval(-MetadataConnectionPool.idleTimeout - 1)
        )
        pool.injectEntry(fresh, scope: scope(connectionId, database: "reports"), lastUsed: now)

        pool.sweepIdleEntries(now: now)

        #expect(pool.pooledDriverCount(for: connectionId) == 1)
        #expect(stale.disconnectCallCount == 1)
        #expect(fresh.disconnectCallCount == 0)
    }

    @Test("a sweep that empties the pool stops the sweeper")
    func sweepStopsWhenThePoolEmpties() {
        let connectionId = UUID()
        let pool = MetadataConnectionPool.isolatedForTesting()
        defer { pool.closeAll(connectionId: connectionId) }

        pool.injectEntry(MockDatabaseDriver(), scope: scope(connectionId, database: "shop"))
        pool.startSweeperForTesting()
        #expect(pool.hasSweeper)

        pool.sweepIdleEntries(now: Date().addingTimeInterval(MetadataConnectionPool.idleTimeout + 1))

        #expect(pool.pooledDriverCount(for: connectionId) == 0)
        #expect(!pool.hasSweeper)
    }

    @Test("staleness is measured against the idle timeout, not the count cap")
    func stalenessIsTimeBased() {
        let used = Date()

        #expect(!MetadataConnectionPool.isStale(used, now: used))
        #expect(!MetadataConnectionPool.isStale(used, now: used.addingTimeInterval(MetadataConnectionPool.idleTimeout - 1)))
        #expect(MetadataConnectionPool.isStale(used, now: used.addingTimeInterval(MetadataConnectionPool.idleTimeout)))
    }
}

@MainActor
struct MetadataConnectionPoolPlanTests {
    @Test("A database-scoped engine keeps its configured database and switches after connecting")
    func planPreservesConfiguredDatabase() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "admin",
            targetDatabase: "newly_created",
            authenticationIsDatabaseScoped: true
        )

        #expect(plan.connectDatabase == "admin")
        #expect(plan.switchDatabase == "newly_created")
    }

    @Test("A database-scoped engine connects directly when it is already the target")
    func planSkipsRedundantSwitch() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "shop",
            targetDatabase: "shop",
            authenticationIsDatabaseScoped: true
        )

        #expect(plan.connectDatabase == "shop")
        #expect(plan.switchDatabase == nil)
    }

    @Test("A database-scoped engine with no configured database connects to the server default")
    func planHandlesBlankConfiguredDatabase() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "",
            targetDatabase: "shop",
            authenticationIsDatabaseScoped: true
        )

        #expect(plan.connectDatabase == "")
        #expect(plan.switchDatabase == "shop")
    }

    @Test("Every other engine still connects straight to the target database")
    func planLeavesOtherEnginesUnchanged() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "shop",
            targetDatabase: "reports",
            authenticationIsDatabaseScoped: false
        )

        #expect(plan.connectDatabase == "reports")
        #expect(plan.switchDatabase == nil)
    }

    /// A pooled entry is pinned once and answered from for the whole idle timeout, and the only
    /// thing that runs between the connect and the first read is the user's own startup commands.
    /// A `USE other` there left every unqualified read answering from `other` while the driver still
    /// reported the database it was asked for.
    @Test("A connection carrying startup commands is put back on its target database")
    func planReassertsAfterStartupCommands() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "shop",
            targetDatabase: "shop",
            authenticationIsDatabaseScoped: false,
            runsStartupCommands: true,
            switchesDatabaseWithoutReconnecting: true
        )

        #expect(plan.connectDatabase == "shop")
        #expect(plan.switchDatabase == "shop")
    }

    @Test("A connection with no startup commands cannot have moved, so nothing is re-asserted")
    func planSkipsReassertWithoutStartupCommands() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "shop",
            targetDatabase: "reports",
            authenticationIsDatabaseScoped: false,
            runsStartupCommands: false,
            switchesDatabaseWithoutReconnecting: true
        )

        #expect(plan.connectDatabase == "reports")
        #expect(plan.switchDatabase == nil)
    }

    /// An engine that reconnects to switch would throw away the startup commands it just ran, and
    /// one that cannot switch at all would fail a connection that works today.
    @Test("An engine that cannot switch on the open connection is left alone")
    func planSkipsReassertWhereSwitchingNeedsAReconnect() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "shop",
            targetDatabase: "shop",
            authenticationIsDatabaseScoped: false,
            runsStartupCommands: true,
            switchesDatabaseWithoutReconnecting: false
        )

        #expect(plan.connectDatabase == "shop")
        #expect(plan.switchDatabase == nil)
    }

    /// An empty database is the server itself, which is not a name any switch can take.
    @Test("A server-scoped connection is never re-asserted onto an empty name")
    func planSkipsReassertForServerScope() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "",
            targetDatabase: "",
            authenticationIsDatabaseScoped: false,
            runsStartupCommands: true,
            switchesDatabaseWithoutReconnecting: true
        )

        #expect(plan.connectDatabase == "")
        #expect(plan.switchDatabase == nil)
    }

    /// Snowflake keys its session on the account and role and not on the database, so every pooled
    /// scope of one connection shares a single mutable `currentDatabase`. Selecting a database on
    /// behalf of one entry selects it for all of them, which would let a structure edit leased for
    /// one database write into another.
    @Test("An engine whose pooled drivers share one session is never re-asserted")
    func planSkipsReassertWhereThePooledSessionIsShared() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "analytics",
            targetDatabase: "analytics",
            authenticationIsDatabaseScoped: false,
            runsStartupCommands: true,
            switchesDatabaseWithoutReconnecting: false
        )

        #expect(plan.connectDatabase == "analytics")
        #expect(plan.switchDatabase == nil)
    }

    @Test("A database-scoped engine still switches to its target, startup commands or not")
    func planKeepsTheDatabaseScopedSwitch() {
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "admin",
            targetDatabase: "newly_created",
            authenticationIsDatabaseScoped: true,
            runsStartupCommands: true,
            switchesDatabaseWithoutReconnecting: true
        )

        #expect(plan.connectDatabase == "admin")
        #expect(plan.switchDatabase == "newly_created")
    }
}
