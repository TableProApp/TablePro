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
}
