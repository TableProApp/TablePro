//
//  DatabaseManagerVersionTests.swift
//  TableProTests
//
//  Tests for fine-grained version counters on DatabaseManager.
//

import Foundation
import Testing
@testable import TablePro

@Suite("DatabaseManager Version Counters")
@MainActor
struct DatabaseManagerVersionTests {
    private func makeSession(id: UUID = UUID()) -> (UUID, ConnectionSession) {
        let connection = DatabaseConnection(id: id, name: "Test")
        let session = ConnectionSession(connection: connection)
        return (id, session)
    }

    @Test("Adding a session increments both connectionListVersion and connectionStatusVersion")
    func addSessionIncrementsBothCounters() {
        let manager = DatabaseManager.shared
        let listBefore = manager.connectionListVersion
        let statusBefore = manager.connectionStatusVersion

        let (id, session) = makeSession()
        manager.injectSession(session, for: id)

        #expect(manager.connectionListVersion == listBefore + 1)
        #expect(manager.connectionStatusVersion == statusBefore + 1)

        manager.removeSession(for: id)
    }

    @Test("Removing a session increments both connectionListVersion and connectionStatusVersion")
    func removeSessionIncrementsBothCounters() {
        let (id, session) = makeSession()
        let manager = DatabaseManager.shared
        manager.injectSession(session, for: id)

        let listBefore = manager.connectionListVersion
        let statusBefore = manager.connectionStatusVersion

        manager.removeSession(for: id)

        #expect(manager.connectionListVersion == listBefore + 1)
        #expect(manager.connectionStatusVersion == statusBefore + 1)
    }

    @Test("Updating a session in-place increments connectionStatusVersion but not connectionListVersion")
    func updateSessionIncrementsOnlyStatusVersion() {
        let (id, session) = makeSession()
        let manager = DatabaseManager.shared
        manager.injectSession(session, for: id)

        let listBefore = manager.connectionListVersion
        let statusBefore = manager.connectionStatusVersion

        manager.updateSession(id) { session in
            session.status = .connected
        }

        #expect(manager.connectionListVersion == listBefore)
        #expect(manager.connectionStatusVersion == statusBefore + 1)

        manager.removeSession(for: id)
    }

    @Test("sessionVersion returns connectionStatusVersion for backward compatibility")
    func sessionVersionBackwardCompat() {
        let manager = DatabaseManager.shared
        #expect(manager.sessionVersion == manager.connectionStatusVersion)

        let (id, session) = makeSession()
        manager.injectSession(session, for: id)

        #expect(manager.sessionVersion == manager.connectionStatusVersion)

        manager.updateSession(id) { session in
            session.status = .connected
        }

        #expect(manager.sessionVersion == manager.connectionStatusVersion)

        manager.removeSession(for: id)
    }

    @Test("Multiple rapid mutations increment counters correctly")
    func rapidMutationsIncrementCorrectly() {
        let manager = DatabaseManager.shared
        let listBefore = manager.connectionListVersion
        let statusBefore = manager.connectionStatusVersion

        let (id1, session1) = makeSession()
        let (id2, session2) = makeSession()

        manager.injectSession(session1, for: id1)
        manager.injectSession(session2, for: id2)

        manager.updateSession(id1) { $0.status = .connected }
        manager.updateSession(id2) { $0.status = .connected }
        manager.updateSession(id1) { $0.status = .error("test") }

        #expect(manager.connectionListVersion == listBefore + 2)
        #expect(manager.connectionStatusVersion == statusBefore + 5)

        manager.removeSession(for: id1)
        manager.removeSession(for: id2)
    }

    @Test("Adding then removing the same session increments both counters twice")
    func addRemoveSameSessionIncrementsTwice() {
        let manager = DatabaseManager.shared
        let listBefore = manager.connectionListVersion
        let statusBefore = manager.connectionStatusVersion

        let (id, session) = makeSession()

        manager.injectSession(session, for: id)
        manager.removeSession(for: id)

        #expect(manager.connectionListVersion == listBefore + 2)
        #expect(manager.connectionStatusVersion == statusBefore + 2)
    }

    @Test("Initial counter values are zero before any test mutations")
    func initialValuesConsistent() {
        let manager = DatabaseManager.shared
        #expect(manager.connectionListVersion >= 0)
        #expect(manager.connectionStatusVersion >= 0)
        #expect(manager.connectionStatusVersion >= manager.connectionListVersion)
    }
}
