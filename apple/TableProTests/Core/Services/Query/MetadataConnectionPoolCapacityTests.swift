//
//  MetadataConnectionPoolCapacityTests.swift
//  TableProTests
//
//  The pool closed at most one idle connection each time a new one was opened, so a burst of opens
//  on distinct keys, which a tree restore or a Refresh of every expanded database produces, left
//  every connection it opened standing until the idle sweep: 13 to 16 backends for one saved
//  connection on a server 1.5 seconds away, against a limit of 6 (#3103). Trimming at the end of
//  the burst still let it dial every key at once, so the limit now holds while the burst runs.
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class StartedTaskBox {
    var task: Task<Void, Error>?
}

/// Holds a lease's body until the test lets it go, so a test can keep work in flight.
@MainActor
private final class LeaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var hasArrived = false

    func wait() async {
        hasArrived = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("MetadataConnectionPool capacity", .serialized)
@MainActor
struct MetadataConnectionPoolCapacityTests {
    private let limit = MetadataConnectionPool.maxPerConnection

    private func makeSession() -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: "shop")
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func scope(_ connection: DatabaseConnection, _ database: String) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: database, schema: nil)
    }

    /// Starts one lease per database, each held open until its gate opens, and waits until every one
    /// of them is running its body.
    private func fill(
        _ pool: MetadataConnectionPool,
        _ connection: DatabaseConnection,
        databases: [String],
        workload: MetadataConnectionPool.Workload = .interactive
    ) async throws -> (gates: [LeaseGate], leases: [Task<Void, Error>]) {
        let gates = databases.map { _ in LeaseGate() }
        let leases = zip(databases, gates).map { database, gate in
            Task { @MainActor in
                try await pool.withDriver(scope: scope(connection, database), workload: workload) { _ in
                    await gate.wait()
                }
            }
        }
        try await waitUntil { gates.allSatisfy(\.hasArrived) }
        return (gates, leases)
    }

    private func release(_ gates: [LeaseGate], _ leases: [Task<Void, Error>]) async {
        gates.forEach { $0.open() }
        for lease in leases {
            _ = try? await lease.value
        }
    }

    @Test("A burst of leases on more keys than the limit leaves no more than the limit open once it ends")
    func burstIsTrimmedWhenItEnds() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener(connectDelaySeconds: 0.05)
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let leases = (0..<limit * 2).map { index in
            Task { @MainActor in
                try await pool.withDriver(scope: scope(connection, "db\(index)")) { _ in
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        for lease in leases {
            try await lease.value
        }

        #expect(opener.opened.count == limit * 2)
        #expect(opener.peakOpenCount == limit)
        #expect(opener.openCount == limit)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
    }

    @Test("A burst on twice the limit never has more than the limit open while it runs")
    func burstNeverRunsPastTheLimit() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let gates = (0..<limit * 2).map { _ in LeaseGate() }
        let leases = gates.enumerated().map { index, gate in
            Task { @MainActor in
                try await pool.withDriver(scope: scope(connection, "db\(index)")) { _ in
                    await gate.wait()
                }
            }
        }
        try await waitUntil {
            gates.filter { $0.hasArrived }.count == limit && pool.roomWaiterCount(for: connection.id) == limit
        }
        #expect(opener.opened.count == limit)
        #expect(opener.peakOpenCount == limit)

        await release(gates, leases)
        #expect(opener.opened.count == limit * 2)
        #expect(opener.peakOpenCount == limit)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
    }

    @Test("A lease waiting for room takes the place of the connection unused longest, never one still working")
    func waitingLeaseTakesOnlyAnIdlePlace() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let databases = (0..<limit).map { "db\($0)" }
        let (gates, leases) = try await fill(pool, connection, databases: databases)
        let extras = ["x0", "x1"].map { database in
            Task { @MainActor in
                try await pool.withDriver(scope: scope(connection, database)) { _ in }
            }
        }
        try await waitUntil { pool.roomWaiterCount(for: connection.id) == 2 }
        #expect(opener.opened.count == limit)

        gates[0].open()
        _ = try? await leases[0].value
        for extra in extras {
            try await extra.value
        }

        #expect(opener.opened.count == limit + 2)
        #expect(opener.openedByDatabase["db0"]?.disconnectCallCount == 1)
        #expect(databases.dropFirst().allSatisfy { opener.openedByDatabase[$0]?.disconnectCallCount == 0 })
        #expect(pool.heldConnectionCount(for: connection.id) == limit)

        await release(gates, leases)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
        #expect(opener.openCount == limit)
    }

    // The outer work holds its connection until the inner lease returns, so making the inner one wait would wait on itself.
    @Test("A lease taken inside another lease's work on the same connection never waits for room", .timeLimit(.minutes(1)))
    func nestedLeaseIsNotHeldBack() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let (gates, leases) = try await fill(pool, connection, databases: (1..<limit).map { "db\($0)" })
        let inner = scope(connection, "inner")
        let innerRanOn = try await pool.withDriver(scope: scope(connection, "outer")) { _ in
            try await pool.withDriver(scope: inner) { driver in ObjectIdentifier(driver) }
        }

        #expect(innerRanOn == opener.openedByDatabase["inner"].map { ObjectIdentifier($0) })
        #expect(opener.opened.count == limit + 1)
        await release(gates, leases)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
    }

    @Test("A lease cancelled while it waits for room stops waiting and opens nothing")
    func cancelledRoomWaiterStopsWaiting() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let (gates, leases) = try await fill(pool, connection, databases: (0..<limit).map { "db\($0)" })
        let waiting = Task { @MainActor in
            try await pool.withDriver(scope: scope(connection, "extra")) { _ in }
        }
        try await waitUntil { pool.roomWaiterCount(for: connection.id) == 1 }

        waiting.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        #expect(pool.roomWaiterCount(for: connection.id) == 0)
        #expect(opener.openedByDatabase["extra"] == nil)
        await release(gates, leases)
        #expect(opener.openedByDatabase["extra"] == nil)
    }

    @Test("Closing the connection fails a lease waiting for room at once")
    func closingTheConnectionFailsRoomWaiters() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let (gates, leases) = try await fill(pool, connection, databases: (0..<limit).map { "db\($0)" })
        let waiting = Task { @MainActor in
            try await pool.withDriver(scope: scope(connection, "extra")) { _ in }
        }
        try await waitUntil { pool.roomWaiterCount(for: connection.id) == 1 }

        pool.closeAll(connectionId: connection.id)
        #expect(pool.roomWaiterCount(for: connection.id) == 0)

        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        await release(gates, leases)
        #expect(opener.openedByDatabase["extra"] == nil)
        #expect(opener.openCount == 0)
    }

    // A completion read or a sidebar expand used to park behind every bulk read of a tree Refresh burst.
    @Test("Freed places go to waiting leases in order, interactive ahead of bulk, and a new lease waits its turn")
    func freedPlacesAreHandedInOrder() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let (gates, leases) = try await fill(pool, connection, databases: (0..<limit).map { "db\($0)" })
        let arrivals: [(String, MetadataConnectionPool.Workload)] = [
            ("b1", .bulk), ("i1", .interactive), ("b2", .bulk), ("i2", .interactive)
        ]
        var waiting: [Task<Void, Error>] = []
        for (database, workload) in arrivals {
            let place = scope(connection, database)
            waiting.append(Task { @MainActor in
                try await pool.withDriver(scope: place, workload: workload) { _ in }
            })
            let parked = waiting.count
            try await waitUntil { pool.roomWaiterCount(for: connection.id) == parked }
        }

        gates[0].open()
        _ = try? await leases[0].value
        try await waiting[1].value
        try await waiting[3].value
        #expect(Array(opener.openOrder.dropFirst(limit)) == ["i1", "i2"])
        #expect(pool.roomWaiterCount(for: connection.id) == 2)

        let lateBulk = scope(connection, "b3")
        let late = Task { @MainActor in
            try await pool.withDriver(scope: lateBulk, workload: .bulk) { _ in }
        }
        try await waitUntil { pool.roomWaiterCount(for: connection.id) == 3 }
        try await pool.withDriver(scope: scope(connection, "i3")) { _ in }
        #expect(Array(opener.openOrder.dropFirst(limit)) == ["i1", "i2", "i3"])

        gates[1].open()
        _ = try? await leases[1].value
        try await waiting[0].value
        try await waiting[2].value
        try await late.value
        #expect(Array(opener.openOrder.dropFirst(limit)) == ["i1", "i2", "i3", "b1", "b2", "b3"])
        await release(gates, leases)
    }

    @Test("Bulk work never takes the last place, so an interactive lease runs while five bulk leases hold the rest")
    func bulkLeavesOnePlaceForInteractive() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let (gates, leases) = try await fill(pool, connection, databases: (0..<limit - 1).map { "bulk\($0)" }, workload: .bulk)
        let sixthBulk = scope(connection, "bulk-extra")
        let waiting = Task { @MainActor in
            try await pool.withDriver(scope: sixthBulk, workload: .bulk) { _ in }
        }
        try await waitUntil { pool.roomWaiterCount(for: connection.id) == 1 }

        try await pool.withDriver(scope: scope(connection, "completion")) { _ in }

        #expect(opener.openedByDatabase["completion"] != nil)
        #expect(opener.openedByDatabase["bulk-extra"] == nil)
        await release(gates, leases)
        try await waiting.value
        #expect(opener.openedByDatabase["bulk-extra"] != nil)
    }

    // A task the body started without awaiting it outlived the lease and kept skipping the limit for good.
    @Test("A task started inside a lease waits for room like any other caller once that lease has ended")
    func taskStartedInALeaseLosesTheExemptionWhenItEnds() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let (gates, leases) = try await fill(pool, connection, databases: (1..<limit).map { "db\($0)" })
        let box = StartedTaskBox()
        let orphanGate = LeaseGate()
        let orphan = scope(connection, "orphan")
        try await pool.withDriver(scope: scope(connection, "outer")) { _ in
            await MainActor.run {
                box.task = Task { @MainActor in
                    await orphanGate.wait()
                    try await pool.withDriver(scope: orphan) { _ in }
                }
            }
        }
        let (lastGate, lastLease) = try await fill(pool, connection, databases: ["db0"])
        #expect(pool.heldConnectionCount(for: connection.id) == limit)

        orphanGate.open()
        try await waitUntil { pool.roomWaiterCount(for: connection.id) == 1 }
        #expect(opener.openedByDatabase["orphan"] == nil)

        await release(gates + lastGate, leases + lastLease)
        try await box.task?.value
        #expect(opener.openedByDatabase["orphan"] != nil)
    }

    /// The open's callers take the entry a scheduler turn after it lands. A lease that asked for
    /// another key in between used to find it idle, close it, and fail every one of them with "Not
    /// connected to database" on a working connection.
    @Test("A connection just opened is never closed before the callers waiting on it take it")
    func unclaimedEntryIsNotEvicted() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let (gates, leases) = try await fill(pool, connection, databases: (1..<limit).map { "db\($0)" })
        var late: Task<Void, Error>?
        opener.afterOpen = { opened in
            guard opened.database == "fresh", late == nil else { return }
            late = Task { @MainActor in
                try await pool.withDriver(scope: scope(connection, "late")) { _ in }
            }
        }

        let first = Task { @MainActor in
            try await pool.withDriver(scope: scope(connection, "fresh")) { driver in ObjectIdentifier(driver) }
        }
        let second = Task { @MainActor in
            try await pool.withDriver(scope: scope(connection, "fresh")) { driver in ObjectIdentifier(driver) }
        }
        let firstRanOn = try await first.value
        let secondRanOn = try await second.value
        try await late?.value

        #expect(firstRanOn == secondRanOn)
        #expect(opener.opened.count == limit + 1)
        await release(gates, leases)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
    }

    /// Joining an open that has already finished returns without a suspension. A caller that joined
    /// one whose connection was already gone came straight back to it, forever, on the main actor.
    @Test(
        "A caller that finds a connection dead as it lands opens a new one instead of rejoining the spent open",
        .timeLimit(.minutes(1))
    )
    func deadOnArrivalEntryIsReopened() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }
        opener.deadOnArrival = ["fresh"]

        var third: Task<ObjectIdentifier, Error>?
        opener.afterOpen = { opened in
            guard opened.database == "fresh", third == nil else { return }
            third = Task { @MainActor in
                try await pool.withDriver(scope: scope(connection, "fresh")) { driver in ObjectIdentifier(driver) }
            }
        }
        let first = Task { @MainActor in
            try await pool.withDriver(scope: scope(connection, "fresh")) { driver in ObjectIdentifier(driver) }
        }
        let second = Task { @MainActor in
            try await pool.withDriver(scope: scope(connection, "fresh")) { driver in ObjectIdentifier(driver) }
        }
        let firstRanOn = try await first.value
        let secondRanOn = try await second.value
        let thirdRanOn = try await third?.value

        let healthy = opener.openedByDatabase["fresh"].map { ObjectIdentifier($0) }
        #expect(opener.opened.count == 2)
        #expect(opener.opened.first?.disconnectCallCount == 1)
        #expect(firstRanOn == healthy)
        #expect(secondRanOn == healthy)
        #expect(thirdRanOn == healthy)
    }
}

@MainActor
struct SessionRemovalClosesPoolTests {
    @Test("A connect that fails over an existing session closes the pooled connections it held")
    func failedConnectClosesThePool() {
        let connection = TestFixtures.makeConnection(database: "shop")
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let pooled = MockDatabaseDriver(connection: connection)
        MetadataConnectionPool.shared.injectEntry(
            pooled,
            scope: DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        )
        defer { MetadataConnectionPool.shared.closeAll(connectionId: connection.id) }

        DatabaseManager.shared.finalizeConnectionFailure(for: connection.id, cancelled: false)

        #expect(DatabaseManager.shared.session(for: connection.id) == nil)
        #expect(MetadataConnectionPool.shared.pooledDriverCount(for: connection.id) == 0)
        #expect(pooled.disconnectCallCount == 1)
    }
}
