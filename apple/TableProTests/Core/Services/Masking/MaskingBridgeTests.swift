//
//  MaskingBridgeTests.swift
//  TableProTests
//
//  MCP tools, the AI chat tools, AppleScript and Shortcuts all read rows through DatabaseAccessBridge.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

@Suite(.serialized)
@MainActor
struct MaskingBridgeTests {
    private static let customers = ScriptAnsweringDriver.resultSet(
        columns: ["id", "email"],
        rows: [["1", "jane@example.com"], ["2", "john@example.com"]]
    )

    private func install(type: DatabaseType = .mysql, sendsBatchesWhole: Bool = true) -> (ScriptAnsweringDriver, DatabaseScope) {
        var connection = TestFixtures.makeConnection(database: "shop", type: type)
        connection.maskingRules = [MaskingRule(pattern: "*.email")]
        let driver = ScriptAnsweringDriver(
            connection: connection,
            sendsBatchesWhole: sendsBatchesWhole,
            answer: { _ in ScriptAnsweringDriver.batch([Self.customers, Self.customers]) },
            statementAnswer: { _ in Self.customers }
        )
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (driver, DatabaseScope(connectionId: connection.id, database: "shop", schema: nil))
    }

    private static func leaks(_ result: QueryResult) -> Bool {
        result.rows.flatMap { $0 }.contains { $0.asText?.contains("@example.com") == true }
    }

    @Test("A statement read for MCP, the assistant or a script comes back masked")
    func statementIsMasked() async throws {
        let (driver, scope) = install()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: scope, query: "SELECT id, email FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(!Self.leaks(outcome.result))
        #expect(outcome.result.rows.map { $0[0] } == [.text("1"), .text("2")])
    }

    @Test("Every result set of a script comes back masked")
    func scriptIsMasked() async throws {
        let (driver, scope) = install(type: .mssql)
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let outcome = try await DatabaseAccessBridge().runScript(
            scope: scope,
            query: "SELECT * FROM customers\nGO\nSELECT * FROM customers",
            maxRows: 10,
            timeoutSeconds: 30,
            cancellation: nil
        )

        #expect(!outcome.resultSets.isEmpty)
        #expect(!outcome.resultSets.contains(where: Self.leaks))
        #expect(!Self.leaks(outcome.primary))
    }

    @Test("What an MCP client receives as JSON holds no masked value")
    func mcpPayloadIsMasked() async throws {
        let (driver, scope) = install()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let payload = try await MCPConnectionBridge().executeQuery(
            scope: scope, query: "SELECT id, email FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        let json = payload.jsonString(prettyPrinted: false)
        #expect(!json.contains("@example.com"))
        #expect(json.contains("••••"))
    }

    @Test("A table.column rule matches by table when the caller names the table")
    func maskingTableNarrowsTheMatch() async throws {
        var connection = TestFixtures.makeConnection(database: "shop")
        connection.maskingRules = [MaskingRule(pattern: "users.email")]
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: { _ in Self.customers })
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let bridge = DatabaseAccessBridge()

        let other = try await bridge.runStatement(
            scope: scope, query: "SELECT * FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil,
            maskingTable: "customers"
        )
        let unnamed = try await bridge.runStatement(
            scope: scope, query: "SELECT * FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(Self.leaks(other.result))
        #expect(!Self.leaks(unnamed.result))
    }
}
