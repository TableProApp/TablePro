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

@Suite("MetadataConnectionPool timeouts")
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

@Suite("MetadataConnectionPool connection plan")
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
}
