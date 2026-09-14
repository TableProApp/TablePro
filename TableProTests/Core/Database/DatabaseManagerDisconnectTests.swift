//
//  DatabaseManagerDisconnectTests.swift
//  TableProTests
//
//  A disconnect leaves the window open, so the tabs have to be written to disk before the session
//  goes away: the coordinator holding them is torn down straight after, and only the window-close
//  path used to save on its way out. That is how the MCP disconnect tool and Reset Sample Database
//  could take a window's tabs with them.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Database manager disconnect", .serialized)
@MainActor
struct DatabaseManagerDisconnectTests {
    private final class TabStatePersisterSpy: SessionTabStatePersisting {
        private(set) var persistedConnectionIds: [UUID] = []
        private(set) var sessionsPresentAtPersist: [Bool] = []

        func persistTabState(for connectionId: UUID) {
            persistedConnectionIds.append(connectionId)
            sessionsPresentAtPersist.append(DatabaseManager.shared.activeSessions[connectionId] != nil)
        }
    }

    private func withInstalledSpy(_ body: (TabStatePersisterSpy) async -> Void) async {
        let spy = TabStatePersisterSpy()
        let previous = DatabaseManager.shared.tabStatePersister
        DatabaseManager.shared.tabStatePersister = spy
        await body(spy)
        DatabaseManager.shared.tabStatePersister = previous
    }

    @Test("Disconnecting persists the connection's tabs while the session still exists")
    func disconnectPersistsTabsBeforeTeardown() async {
        await withInstalledSpy { spy in
            let id = UUID()
            DatabaseManager.shared.injectSession(
                ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Persisted")),
                for: id
            )

            await DatabaseManager.shared.disconnectSession(id)

            #expect(spy.persistedConnectionIds == [id])
            #expect(spy.sessionsPresentAtPersist == [true])
        }
    }

    @Test("A disconnect with no session persists nothing")
    func disconnectWithoutSessionPersistsNothing() async {
        await withInstalledSpy { spy in
            await DatabaseManager.shared.disconnectSession(UUID())

            #expect(spy.persistedConnectionIds.isEmpty)
        }
    }

    @Test("A user-requested disconnect is recorded as deliberate")
    func userRequestedDisconnectIsRecorded() async {
        let id = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Deliberate")),
            for: id
        )
        defer { DatabaseManager.shared.userRequestedDisconnects.remove(id) }

        await DatabaseManager.shared.disconnectSession(id, origin: .userRequested)

        #expect(DatabaseManager.shared.wasDisconnectedByUser(id))
    }

    /// Quitting and closing a window both run through `disconnectSession`. Recording those as
    /// deliberate would drop every connection from "Reopen Last Session", because a deliberate
    /// disconnect is the one unavailable state that does not retain restore intent.
    @Test("An app-managed disconnect is not recorded as deliberate")
    func appManagedDisconnectIsNotRecorded() async {
        let id = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Closed")),
            for: id
        )
        defer { DatabaseManager.shared.userRequestedDisconnects.remove(id) }

        await DatabaseManager.shared.disconnectSession(id)

        #expect(!DatabaseManager.shared.wasDisconnectedByUser(id))
    }

    @Test("Disconnecting removes the session entry")
    func disconnectRemovesSessionEntry() async {
        let id = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id, name: "Gone")),
            for: id
        )
        defer { DatabaseManager.shared.userRequestedDisconnects.remove(id) }

        await DatabaseManager.shared.disconnectSession(id, origin: .userRequested)

        #expect(DatabaseManager.shared.activeSessions[id] == nil)
    }

    /// A driver stuck in a call keeps its turn across a disconnect. Work queued behind it has to end
    /// with the session, or it wakes when that call returns and runs on whatever holds the id then.
    @Test("Disconnecting fails the work still queued for the session's driver")
    func disconnectFailsQueuedDriverWork() async throws {
        let connection = TestFixtures.makeConnection(name: "Queued")
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let gate = DatabaseManager.shared.sessionDriverGate

        let acquired = Latch()
        let release = Latch()
        let holder = Task { @MainActor in
            try await gate.withExclusiveAccess(connection.id) {
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let scope = DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        let lease = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: .sessionDriver,
                cancellation: .cancellableRead
            ) { driver in
                driver.connection.database
            }
        }
        for _ in 0..<10_000 where gate.waiterCount(for: connection.id) < 1 {
            await Task.yield()
        }
        #expect(gate.waiterCount(for: connection.id) == 1)

        await DatabaseManager.shared.disconnectSession(connection.id)

        #expect(gate.waiterCount(for: connection.id) == 0)

        release.open()
        try await holder.value

        await #expect(throws: CancellationError.self) {
            try await lease.value
        }
    }
}

@MainActor
private final class Latch {
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
