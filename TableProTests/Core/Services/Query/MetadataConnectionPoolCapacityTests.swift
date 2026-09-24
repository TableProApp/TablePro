//
//  MetadataConnectionPoolCapacityTests.swift
//  TableProTests
//
//  The pool closed at most one idle connection each time a new one was opened, so a burst of opens
//  on distinct keys, which a tree restore or a Refresh of every expanded database produces, left
//  every connection it opened standing until the idle sweep: 13 to 16 backends for one saved
//  connection on a server 1.5 seconds away, against a limit of 6 (#3103).
//

import Foundation
@testable import TablePro
import Testing

/// Stands in for opening a pooled connection, remembering each driver by the database it was
/// opened for.
@MainActor
private final class CountingOpener {
    private let connectDelaySeconds: Double
    private(set) var opened: [MockDatabaseDriver] = []
    private(set) var openedByDatabase: [String: MockDatabaseDriver] = [:]
    var afterOpen: ((DatabaseScope) -> Void)?
    var deadOnArrival: Set<String> = []

    init(connectDelaySeconds: Double = 0) {
        self.connectDelaySeconds = connectDelaySeconds
    }

    var openCount: Int {
        opened.filter { $0.disconnectCallCount == 0 }.count
    }

    func open(_ scope: DatabaseScope) async throws -> DatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.connectDelaySeconds = connectDelaySeconds
        driver.hasLostConnection = deadOnArrival.remove(scope.database) != nil
        opened.append(driver)
        openedByDatabase[scope.database] = driver
        try await driver.connect()
        afterOpen?(scope)
        return driver
    }
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

    /// Bounded, so a caller that never reaches the point being waited for fails the assertions after
    /// it rather than hanging the suite.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Starts one lease per database, each held open until its gate opens, and waits until every one
    /// of them is running its body.
    private func fill(
        _ pool: MetadataConnectionPool,
        _ connection: DatabaseConnection,
        databases: [String]
    ) async -> (gates: [LeaseGate], leases: [Task<Void, Error>]) {
        let gates = databases.map { _ in LeaseGate() }
        let leases = zip(databases, gates).map { database, gate in
            Task { @MainActor in
                try await pool.withDriver(scope: scope(connection, database)) { _ in
                    await gate.wait()
                }
            }
        }
        await waitUntil { gates.allSatisfy(\.hasArrived) }
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
        #expect(opener.openCount == limit)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
    }

    @Test("Each lease that ends past the limit closes the connection unused longest, never one still working")
    func trimClosesOnlyIdleConnections() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let databases = (0..<limit + 2).map { "db\($0)" }
        let (gates, leases) = await fill(pool, connection, databases: databases)
        #expect(pool.heldConnectionCount(for: connection.id) == limit + 2)

        gates[0].open()
        _ = try? await leases[0].value

        #expect(pool.heldConnectionCount(for: connection.id) == limit + 1)
        #expect(opener.openedByDatabase["db0"]?.disconnectCallCount == 1)
        #expect(databases.dropFirst().allSatisfy { opener.openedByDatabase[$0]?.disconnectCallCount == 0 })

        await release(gates, leases)
        #expect(pool.heldConnectionCount(for: connection.id) == limit)
        #expect(opener.openCount == limit)
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

        let (gates, leases) = await fill(pool, connection, databases: (1..<limit).map { "db\($0)" })
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

@Suite("Session removal and the metadata pool", .serialized)
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
