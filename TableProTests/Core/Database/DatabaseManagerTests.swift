//
//  DatabaseManagerTests.swift
//  TableProTests
//
//  Tests for DatabaseManager session-scoped accessors.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DatabaseManager Session-Scoped Accessors")
@MainActor
struct DatabaseManagerSessionTests {
    @Test("driver(for:) returns nil for unknown connection ID")
    func driverReturnsNilForUnknown() {
        let unknownId = UUID()
        #expect(DatabaseManager.shared.driver(for: unknownId) == nil)
    }

    @Test("session(for:) returns nil for unknown connection ID")
    func sessionReturnsNilForUnknown() {
        let unknownId = UUID()
        #expect(DatabaseManager.shared.session(for: unknownId) == nil)
    }

    @Test("activeSessions is accessible and starts empty for unknown IDs")
    func activeSessionsAccessible() {
        let unknownId = UUID()
        let session = DatabaseManager.shared.activeSessions[unknownId]
        #expect(session == nil)
    }

    @Test("resolvedSchemaName keeps an explicit schema over the session's current schema")
    func resolvedSchemaNameKeepsExplicitSchema() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.currentSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName("audit", for: connection.id) == "audit")
    }

    @Test("resolvedSchemaName falls back to the session's current schema")
    func resolvedSchemaNameFallsBackToSessionSchema() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.currentSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, for: connection.id) == "sales")
    }

    @Test("resolvedSchemaName stays nil without a session")
    func resolvedSchemaNameStaysNilWithoutSession() {
        #expect(DatabaseManager.shared.resolvedSchemaName(nil, for: UUID()) == nil)
    }

    @Test("resolvedSchemaName stays nil for a schema-less session")
    func resolvedSchemaNameStaysNilForSchemaLessSession() {
        let connection = TestFixtures.makeConnection()
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, for: connection.id) == nil)
    }
}
