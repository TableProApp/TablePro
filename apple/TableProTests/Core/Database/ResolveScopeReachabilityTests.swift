//
//  ResolveScopeReachabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

// A statement is pinned only to a container its engine can switch to, so a name it cannot reach is refused up front
// rather than dropped at the pin, where the statement would run in the session's own database.
@MainActor
struct ResolveScopeReachabilityTests {
    // `reported` is what the connect captures from the driver as the database it opened; SQLite reports its file.
    private func session(_ type: DatabaseType, database: String, reported: String? = nil) -> ScriptAnsweringDriver {
        var connection = TestFixtures.makeConnection(database: database, type: type)
        connection.aiPolicy = .alwaysAllow
        let driver = ScriptAnsweringDriver(connection: connection)
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        session.openedDatabase = reported
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return driver
    }

    @Test("A fixed-database connection refuses another database and keeps its own")
    func fixedDatabaseRefusesAnother() async throws {
        let driver = session(.sqlite, database: "prod.sqlite", reported: "prod.sqlite")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let bridge = DatabaseAccessBridge()
        let id = driver.connection.id

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.resolveScope(connectionId: id, database: "staging.sqlite", schema: nil)
        }
        let named = try await bridge.resolveScope(connectionId: id, database: "prod.sqlite", schema: nil)
        let unnamed = try await bridge.resolveScope(connectionId: id, database: nil, schema: nil)
        #expect(named.database == "prod.sqlite")
        #expect(unnamed.database == "prod.sqlite")
    }

    @Test("An engine with no schema switching refuses a schema for SQL, hands it to a catalog read, and takes another database")
    func schemaLessEngineRefusesASchemaForSQL() async throws {
        let driver = session(.mysql, database: "shop")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let bridge = DatabaseAccessBridge()
        let id = driver.connection.id

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: "archive")
        }
        let catalog = try await bridge.resolveScope(connectionId: id, database: nil, schema: "archive")
        let other = try await bridge.resolveScope(connectionId: id, database: "warehouse", schema: nil)
        #expect(catalog.schema == "archive")
        #expect(other.database == "warehouse")
    }

    @Test("A schema-switching engine still takes another schema")
    func schemaEngineTakesASchema() async throws {
        let driver = session(.postgresql, database: "shop")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let scope = try await DatabaseAccessBridge().resolveScope(
            connectionId: driver.connection.id, database: nil, schema: "archive"
        )

        #expect(scope.schema == "archive")
    }

    @Test("MCP execute_query naming another database on a fixed-database connection runs nothing")
    func mcpExecuteQueryRefusesAnotherDatabase() async {
        let driver = session(.sqlite, database: "prod.sqlite")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil }, connectionIdsProvider: { [] }, historyRecorder: DiscardingHistory()
            )
        )

        await #expect(throws: (any Error).self) {
            _ = try await ExecuteQueryTool().perform(
                arguments: .object([
                    "connection_id": .string(driver.connection.id.uuidString),
                    "query": .string("SELECT * FROM orders"),
                    "database": .string("staging.sqlite")
                ]),
                context: MCPToolTestHarness.context(),
                services: services
            )
        }

        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }
}
