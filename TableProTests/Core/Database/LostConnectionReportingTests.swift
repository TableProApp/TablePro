//
//  LostConnectionReportingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Plugin driver adapter and a lost connection")
struct PluginDriverAdapterLostConnectionTests {
    @Test("the adapter forwards the driver's lost connection and leaves its own status alone")
    func forwardsTheFactWithoutRewritingStatus() async throws {
        let plugin = FakeMSSQLPluginDriver()
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: plugin)
        try await adapter.connect()

        plugin.hasLostConnection = true

        #expect(adapter.hasLostConnection)
        #expect(adapter.status == .connected)
    }
}

@Suite("Metadata pool and a lost connection", .serialized)
@MainActor
struct MetadataConnectionPoolLostEntryTests {
    /// The shared pool on purpose: this is the one production uses, and opening a real entry on it
    /// is what starts its sweeper.
    @Test("a pooled driver that reported a lost connection is replaced instead of reused")
    func lostEntryIsRebuilt() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        session.driver = MockDatabaseDriver(connection: connection)
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let pool = MetadataConnectionPool.shared
        defer {
            pool.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }

        let scope = DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        let plugin = FakeMSSQLPluginDriver()
        let lost = PluginDriverAdapter(connection: connection, pluginDriver: plugin)
        try await lost.connect()
        pool.injectEntry(lost, scope: scope)
        plugin.hasLostConnection = true

        let reused = try await pool.withDriver(scope: scope) { driver in driver === lost }

        #expect(!reused)
        #expect(plugin.disconnectCallCount == 1)
        #expect(pool.hasSweeper)
    }
}
