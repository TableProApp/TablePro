//
//  MetadataConnectionPoolSharingTests.swift
//  TableProTests
//
//  Connecting to PostgreSQL and opening one table opened three server connections: the session and
//  two pooled ones, the second only because a bulk read would not take the idle interactive one. Each
//  is a whole startup in front of the read that waits for it (#4542).
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class HeldLease {
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

@MainActor
struct MetadataConnectionPoolSharingTests {
    private func makeSession() -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: "shop")
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func scope(_ connection: DatabaseConnection) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
    }

    @Test("A bulk read runs on the idle interactive connection instead of dialing one of its own")
    func bulkTakesIdleInteractiveEntry() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }

        let interactive = try await pool.withDriver(scope: scope(connection)) { ObjectIdentifier($0) }
        let bulk = try await pool.withDriver(scope: scope(connection), workload: .bulk) { ObjectIdentifier($0) }

        #expect(opener.opened.count == 1)
        #expect(bulk == interactive)
    }

    @Test("An interactive read does not queue behind bulk work that borrowed its connection")
    func interactiveSkipsEntryLentToBulk() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }
        let place = scope(connection)
        let first = try await pool.withDriver(scope: place) { ObjectIdentifier($0) }

        let held = HeldLease()
        let bulk = Task { @MainActor in
            try await pool.withDriver(scope: place, workload: .bulk) { driver -> ObjectIdentifier in
                await held.wait()
                return ObjectIdentifier(driver)
            }
        }
        try await waitUntil { held.hasArrived }
        let interactive = try await pool.withDriver(scope: place) { ObjectIdentifier($0) }
        held.open()
        let borrowed = try await bulk.value

        #expect(borrowed == first)
        #expect(interactive != first)
        #expect(opener.opened.count == 2)
    }

    @Test("A prewarm dials the scope's connection once, and the first read takes it without dialing")
    func prewarmDialsOnceAndIsTaken() async throws {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let opener = CountingOpener()
        let pool = MetadataConnectionPool.isolatedForTesting(openDriver: { try await opener.open($0) })
        defer { pool.closeAll(connectionId: connection.id) }
        let place = scope(connection)

        pool.prewarm(scope: place)
        pool.prewarm(scope: place)
        try await waitUntil { pool.pooledDriverCount(for: connection.id) == 1 }
        #expect(pool.hasIdleEntry(for: place))

        let served = try await pool.withDriver(scope: place) { ObjectIdentifier($0) }
        pool.prewarm(scope: place)

        #expect(opener.opened.count == 1)
        #expect(served == opener.opened.first.map { ObjectIdentifier($0) })
    }
}
