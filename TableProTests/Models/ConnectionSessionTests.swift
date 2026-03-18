//
//  ConnectionSessionTests.swift
//  TableProTests
//
//  Tests for ConnectionSession.isContentViewEquivalent — verifies which
//  field changes trigger SwiftUI re-renders and which are ignored.
//

import Foundation
import Testing

@testable import TablePro

@Suite("ConnectionSession.isContentViewEquivalent")
struct ConnectionSessionEquivalenceTests {
    // MARK: - Helpers

    private func makeSession(
        id: UUID = UUID(),
        database: String = "testdb",
        type: DatabaseType = .mysql,
        tables: [TableInfo] = [],
        status: ConnectionStatus = .connected
    ) -> ConnectionSession {
        let connection = DatabaseConnection(
            id: id,
            name: "Test",
            database: database,
            type: type
        )
        var session = ConnectionSession(connection: connection)
        session.status = status
        session.tables = tables
        return session
    }

    // MARK: - Equality

    @Test("Returns true for identical sessions")
    func identicalSessionsAreEquivalent() {
        let id = UUID()
        let a = makeSession(id: id, database: "mydb")
        let b = makeSession(id: id, database: "mydb")
        #expect(a.isContentViewEquivalent(to: b))
    }

    @Test("Returns true when only volatile fields change")
    func trueWhenOnlyVolatileFieldsChange() {
        let id = UUID()
        var a = makeSession(id: id, database: "mydb")
        var b = makeSession(id: id, database: "mydb")

        // lastActiveAt differs — this is a volatile field excluded from comparison
        a.lastActiveAt = Date(timeIntervalSince1970: 1_000)
        b.lastActiveAt = Date(timeIntervalSince1970: 2_000)

        // lastError differs — excluded from comparison
        a.lastError = "something"
        b.lastError = nil

        #expect(a.isContentViewEquivalent(to: b))
    }

    // MARK: - Inequality

    @Test("Returns false when database changes")
    func falseWhenDatabaseChanges() {
        let id = UUID()
        let a = makeSession(id: id, database: "db_a")
        let b = makeSession(id: id, database: "db_b")
        #expect(!a.isContentViewEquivalent(to: b))
    }

    @Test("Returns false when tables change")
    func falseWhenTablesChange() {
        let id = UUID()
        var a = makeSession(id: id)
        var b = makeSession(id: id)

        a.tables = [TestFixtures.makeTableInfo(name: "users")]
        b.tables = [TestFixtures.makeTableInfo(name: "orders")]

        #expect(!a.isContentViewEquivalent(to: b))
    }

    @Test("Returns false when status changes")
    func falseWhenStatusChanges() {
        let id = UUID()
        let a = makeSession(id: id, status: .connected)
        let b = makeSession(id: id, status: .disconnected)
        #expect(!a.isContentViewEquivalent(to: b))
    }

    @Test("Returns false when currentSchema changes")
    func falseWhenCurrentSchemaChanges() {
        let id = UUID()
        var a = makeSession(id: id)
        var b = makeSession(id: id)

        a.currentSchema = "public"
        b.currentSchema = "private"

        #expect(!a.isContentViewEquivalent(to: b))
    }

    @Test("Returns false when pendingTruncates change")
    func falseWhenPendingTruncatesChange() {
        let id = UUID()
        var a = makeSession(id: id)
        var b = makeSession(id: id)

        a.pendingTruncates = ["users"]
        b.pendingTruncates = []

        #expect(!a.isContentViewEquivalent(to: b))
    }

    @Test("Returns true when selectedTables change (ephemeral UI state)")
    func trueWhenSelectedTablesChange() {
        let id = UUID()
        var a = makeSession(id: id)
        var b = makeSession(id: id)

        a.selectedTables = [TestFixtures.makeTableInfo(name: "users")]
        b.selectedTables = []

        #expect(a.isContentViewEquivalent(to: b))
    }
}

@Suite("ConnectionSession State")
struct ConnectionSessionStateTests {
    private func makeSession(status: ConnectionStatus = .disconnected) -> ConnectionSession {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.status = status
        return session
    }

    @Test("isConnected returns true only for .connected")
    func isConnectedTrueWhenConnected() {
        var session = makeSession()
        session.status = .connected
        #expect(session.isConnected)
    }

    @Test("isConnected returns false for .disconnected")
    func isConnectedFalseWhenDisconnected() {
        let session = makeSession(status: .disconnected)
        #expect(!session.isConnected)
    }

    @Test("isConnected returns false for .connecting")
    func isConnectedFalseWhenConnecting() {
        let session = makeSession(status: .connecting)
        #expect(!session.isConnected)
    }

    @Test("isConnected returns false for .error")
    func isConnectedFalseWhenError() {
        let session = makeSession(status: .error("test error"))
        #expect(!session.isConnected)
    }

    @Test("clearCachedData clears tables")
    func clearCachedDataClearsTables() {
        var session = makeSession()
        session.tables = [TestFixtures.makeTableInfo(name: "users")]
        session.clearCachedData()
        #expect(session.tables.isEmpty)
    }

    @Test("clearCachedData clears selectedTables")
    func clearCachedDataClearsSelectedTables() {
        var session = makeSession()
        session.selectedTables = [TestFixtures.makeTableInfo(name: "users")]
        session.clearCachedData()
        #expect(session.selectedTables.isEmpty)
    }

    @Test("clearCachedData clears pendingTruncates")
    func clearCachedDataClearsPendingTruncates() {
        var session = makeSession()
        session.pendingTruncates = ["users", "orders"]
        session.clearCachedData()
        #expect(session.pendingTruncates.isEmpty)
    }

    @Test("clearCachedData clears pendingDeletes")
    func clearCachedDataClearsPendingDeletes() {
        var session = makeSession()
        session.pendingDeletes = ["users", "orders"]
        session.clearCachedData()
        #expect(session.pendingDeletes.isEmpty)
    }

    @Test("clearCachedData clears tableOperationOptions")
    func clearCachedDataClearsTableOperationOptions() {
        var session = makeSession()
        session.tableOperationOptions = ["users": TableOperationOptions()]
        session.clearCachedData()
        #expect(session.tableOperationOptions.isEmpty)
    }

    @Test("clearCachedData preserves connection and status")
    func clearCachedDataPreservesConnectionAndStatus() {
        let connection = TestFixtures.makeConnection(name: "Production")
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        session.tables = [TestFixtures.makeTableInfo(name: "users")]
        session.clearCachedData()
        #expect(session.status == .connected)
        #expect(session.connection.id == connection.id)
    }

    @Test("markActive updates lastActiveAt")
    func markActiveUpdatesLastActiveAt() async throws {
        var session = makeSession()
        try await Task.sleep(for: .milliseconds(10))
        session.markActive()
        #expect(session.lastActiveAt > session.connectedAt)
    }

    @Test("id matches connection.id")
    func idMatchesConnectionId() {
        let connection = TestFixtures.makeConnection()
        let session = ConnectionSession(connection: connection)
        #expect(session.id == connection.id)
    }
}
