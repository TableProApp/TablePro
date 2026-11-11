//
//  MetadataConnectionPoolSchemaTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private struct SchemaSighting: Equatable, Sendable {
    let driver: ObjectIdentifier
    let schema: String?

    init(_ driver: DatabaseDriver) {
        self.driver = ObjectIdentifier(driver)
        schema = (driver as? MockDatabaseDriver)?.currentSchema
    }
}

private struct NestedSighting: Sendable {
    let outer: SchemaSighting
    let inner: SchemaSighting
}

@MainActor
private final class SchemaLeaseLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

// Each schema of a database held its own pooled connection, so work across three schemas at the cap evicted and redialed.
@Suite("MetadataConnectionPool schemas", .serialized)
@MainActor
struct MetadataConnectionPoolSchemaTests {
    private let limit = MetadataConnectionPool.maxPerConnection

    private func makeSession(startupCommands: String? = nil) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(database: "shop")
        connection.startupCommands = startupCommands
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func scope(_ connection: DatabaseConnection, _ schema: String?) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "shop", schema: schema)
    }

    private func probe(_ pool: MetadataConnectionPool, _ scope: DatabaseScope) async throws -> SchemaSighting {
        try await pool.withDriver(scope: scope) { driver in SchemaSighting(driver) }
    }

    @Test("Leases on three schemas of one database, one after another, open one connection")
    func schemasOfOneDatabaseShareAnIdleConnection() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        for schema in ["a", "b", "c"] {
            _ = try await probe(pool, scope(connection, schema))
        }

        #expect(opener.opened.count == 1)
        #expect(pool.pooledDriverCount(for: connection.id) == 1)
    }

    @Test("Each lease reads on its own schema, so a shared connection is moved before every change of schema")
    func leaseRunsOnItsOwnSchema() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        var sightings: [SchemaSighting] = []
        for schema in ["a", "b", "a"] {
            sightings.append(try await probe(pool, scope(connection, schema)))
        }
        let schemas = sightings.map { $0.schema }
        let drivers = Set(sightings.map { $0.driver })

        #expect(schemas == ["a", "b", "a"])
        #expect(drivers.count == 1)
        #expect(opener.opened.first?.switchSchemaCallCount == 3)
    }

    // One connection per database would make a schema's reads wait behind another schema's long lease.
    @Test("A lease on another schema opens its own connection while the first schema's lease still runs", .timeLimit(.minutes(1)))
    func busySchemaOpensASiblingForAnotherSchema() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let gate = AsyncGate()
        let held = scope(connection, "a")
        let holding = Task { @MainActor in
            try await pool.withDriver(scope: held) { driver in
                await gate.wait()
                return ObjectIdentifier(driver)
            }
        }
        await gate.arrived(1)

        let sibling = try await probe(pool, scope(connection, "b"))
        #expect(opener.opened.count == 2)

        await gate.open()
        let heldOn = try await holding.value
        #expect(sibling.driver != heldOn)
        #expect(sibling.schema == "b")
    }

    @Test("Two leases on one schema at once queue on one connection")
    func sameSchemaStillQueuesOnItsConnection() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let gate = AsyncGate()
        let log = SchemaLeaseLog()
        let place = scope(connection, "a")
        let first = Task { @MainActor in
            try await pool.withDriver(scope: place) { driver in
                await gate.wait()
                await log.record("first")
                return ObjectIdentifier(driver)
            }
        }
        await gate.arrived(1)
        let second = Task { @MainActor in
            try await pool.withDriver(scope: place) { driver in
                await log.record("second")
                return ObjectIdentifier(driver)
            }
        }
        try await waitUntil { pool.leaseCount(for: connection.id) == 2 }
        #expect(opener.opened.count == 1)

        await gate.open()
        let firstRanOn = try await first.value
        let secondRanOn = try await second.value

        #expect(firstRanOn == secondRanOn)
        #expect(log.entries == ["first", "second"])
        #expect(opener.opened.count == 1)
    }

    // Data Compare and Object Copy lease one side inside the other, and both sides stream at once.
    @Test(
        "A lease nested in another schema's lease gets its own connection, past the limit when it is full",
        .timeLimit(.minutes(1))
    )
    func nestedLeaseOnAnotherSchemaGetsItsOwnConnection() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let gate = AsyncGate()
        let fills = (1..<limit).map { index in
            let place = DatabaseScope(connectionId: connection.id, database: "db\(index)", schema: nil)
            return Task { @MainActor in
                try await pool.withDriver(scope: place) { _ in await gate.wait() }
            }
        }
        await gate.arrived(limit - 1)

        let outer = scope(connection, "a")
        let inner = scope(connection, "b")
        let ranOn = try await pool.withDriver(scope: outer) { outerDriver in
            let innerSighting = try await pool.withDriver(scope: inner) { innerDriver in SchemaSighting(innerDriver) }
            return NestedSighting(outer: SchemaSighting(outerDriver), inner: innerSighting)
        }

        #expect(ranOn.outer.driver != ranOn.inner.driver)
        #expect(ranOn.outer.schema == "a")
        #expect(ranOn.inner.schema == "b")
        #expect(opener.opened.count == limit + 1)

        await gate.open()
        for fill in fills {
            try await fill.value
        }
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
    }

    // The outer lease's connection runs its work serially, so the inner lease would wait on a tail only the outer can finish.
    @Test("A lease nested in a lease on the same schema gets its own connection", .timeLimit(.minutes(1)))
    func nestedLeaseOnTheSameSchemaGetsItsOwnConnection() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let place = scope(connection, "a")
        let ranOn = try await pool.withDriver(scope: place) { outerDriver in
            let innerSighting = try await pool.withDriver(scope: place) { innerDriver in SchemaSighting(innerDriver) }
            return NestedSighting(outer: SchemaSighting(outerDriver), inner: innerSighting)
        }

        #expect(ranOn.outer.driver != ranOn.inner.driver)
        #expect(ranOn.inner.schema == "a")
        #expect(opener.opened.count == 2)
    }

    // Two Data Compares between the same two schemas, run in opposite directions, each hold one side and ask for the other.
    @Test("Two leases nesting in opposite directions on two schemas both finish", .timeLimit(.minutes(1)))
    func leasesNestingInOppositeDirectionsBothFinish() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let outerGate = AsyncGate()
        let innerGate = AsyncGate()
        let first = scope(connection, "a")
        let second = scope(connection, "b")
        let forward = Task { @MainActor in
            try await pool.withDriver(scope: first) { outerDriver in
                await outerGate.wait()
                let inner = try await pool.withDriver(scope: second) { innerDriver in
                    await innerGate.wait()
                    return SchemaSighting(innerDriver)
                }
                return NestedSighting(outer: SchemaSighting(outerDriver), inner: inner)
            }
        }
        let backward = Task { @MainActor in
            try await pool.withDriver(scope: second) { outerDriver in
                await outerGate.wait()
                let inner = try await pool.withDriver(scope: first) { innerDriver in
                    await innerGate.wait()
                    return SchemaSighting(innerDriver)
                }
                return NestedSighting(outer: SchemaSighting(outerDriver), inner: inner)
            }
        }
        await outerGate.arrived(2)
        await outerGate.open()
        await innerGate.arrived(2)
        #expect(opener.opened.count == 4)

        await innerGate.open()
        let forwardRan = try await forward.value
        let backwardRan = try await backward.value

        #expect(forwardRan.outer.schema == "a")
        #expect(forwardRan.inner.schema == "b")
        #expect(backwardRan.outer.schema == "b")
        #expect(backwardRan.inner.schema == "a")
        #expect(forwardRan.inner.driver != backwardRan.outer.driver)
        #expect(backwardRan.inner.driver != forwardRan.outer.driver)
    }

    @Test("A lease with no schema runs on a connection no lease ever moves")
    func leaseWithNoSchemaNeverMovesItsConnection() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let onSchema = try await probe(pool, scope(connection, "a"))
        let home = try await probe(pool, scope(connection, nil))
        let homeDriver = opener.opened.first(where: { ObjectIdentifier($0) == home.driver })

        #expect(home.driver != onSchema.driver)
        #expect(home.schema == nil)
        #expect(homeDriver?.switchSchemaCallCount == 0)
    }

    // A startup command can move the search path after the driver read it, so the driver's own answer is not trusted once.
    @Test("A connection that ran startup commands switches on its first lease even when the driver reports the schema")
    func startupCommandsForceTheFirstSwitch() async throws {
        let connection = makeSession(startupCommands: "SET search_path = app")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        opener.configure = { $0.currentSchema = "public" }
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let first = try await probe(pool, scope(connection, "public"))
        let driver = try #require(opener.opened.first)
        #expect(driver.switchSchemaCallCount == 1)

        let second = try await probe(pool, scope(connection, "public"))
        #expect(driver.switchSchemaCallCount == 1)
        #expect(second.driver == first.driver)
    }

    // A rollback undoes a schema switch sent inside the transaction while the driver keeps the new name.
    @Test("An idle connection left in a transaction is closed instead of switched, and the lease opens another")
    func switchInsideAnOpenTransactionTakesAnotherConnection() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let first = try await probe(pool, scope(connection, "a"))
        let stuck = try #require(opener.opened.first)
        stuck.sessionTransactionStateToReturn = .inTransaction

        let moved = try await probe(pool, scope(connection, "b"))

        #expect(moved.driver != first.driver)
        #expect(moved.schema == "b")
        #expect(stuck.currentSchema == "a")
        #expect(stuck.switchSchemaCallCount == 1)
        #expect(stuck.disconnectCallCount == 1)
        #expect(opener.opened.count == 2)
        #expect(pool.pooledDriverCount(for: connection.id) == 1)
    }

    @Test("A switch that fails fails only its own lease, and the connection serves the next one")
    func failedSwitchFailsOnlyThatLease() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let first = try await probe(pool, scope(connection, "a"))
        let driver = try #require(opener.opened.first)
        driver.switchSchemaError = ("bad", DatabaseError.queryFailed("schema \"bad\" does not exist"))
        let log = SchemaLeaseLog()
        let bad = scope(connection, "bad")

        await #expect(throws: DatabaseError.self) {
            try await pool.withDriver(scope: bad) { _ in await log.record("bad") }
        }
        let next = try await probe(pool, scope(connection, "a"))

        #expect(log.entries.isEmpty)
        #expect(next.driver == first.driver)
        #expect(next.schema == "a")
        // The failed statement may have reached the server, so the next lease sends its switch again.
        #expect(driver.switchSchemaCallCount == 2)
        #expect(driver.disconnectCallCount == 0)
        #expect(opener.opened.count == 1)
    }

    @Test("Ten schemas at once never hold more connections than the limit, and the waiting ones reuse those")
    func burstAcrossTenSchemasHoldsNoMoreThanItRuns() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let schemas = (0..<10).map { "s\($0)" }
        let expected: [String?] = schemas
        let gate = AsyncGate()
        let leases = schemas.map { schema in
            let place = scope(connection, schema)
            return Task { @MainActor in
                try await pool.withDriver(scope: place) { driver in
                    await gate.wait()
                    return (driver as? MockDatabaseDriver)?.currentSchema
                }
            }
        }
        await gate.arrived(limit)
        try await waitUntil { pool.roomWaiterCount(for: connection.id) == schemas.count - limit }
        #expect(opener.opened.count == limit)

        await gate.open()
        var ranOn: [String?] = []
        for lease in leases {
            ranOn.append(try await lease.value)
        }
        #expect(ranOn == expected)
        #expect(opener.opened.count == limit)
        #expect(opener.peakOpenCount == limit)

        var later: [String?] = []
        for schema in schemas {
            later.append(try await probe(pool, scope(connection, schema)).schema)
        }
        #expect(later == expected)
        #expect(opener.opened.count == limit)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
    }
}
