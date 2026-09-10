//
//  MCPCatalogToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Enumerated tool arguments are checked, never guessed")
struct MCPEnumeratedArgumentTests {
    private func call(
        _ tool: any MCPToolImplementation,
        _ arguments: JsonValue
    ) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("drop_database_object only accepts the kinds it declares")
    func dropDatabaseObjectKinds() async throws {
        #expect(DropDatabaseObjectTool.requiredScopes == [.toolsWrite])
        #expect(DropDatabaseObjectTool.kinds == ["database", "schema"])

        let result = try await call(
            DropDatabaseObjectTool(),
            .object([
                "connection_id": .string(UUID().uuidString),
                "kind": .string("table"),
                "name": .string("users")
            ])
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.contains("database"))
        #expect(text.contains("schema"))
    }

    @Test("transaction_control only accepts begin, commit and rollback")
    func transactionControlActions() async throws {
        #expect(TransactionControlTool.requiredScopes == [.toolsWrite])
        #expect(TransactionControlTool.actions == ["begin", "commit", "rollback"])

        let result = try await call(
            TransactionControlTool(),
            .object([
                "connection_id": .string(UUID().uuidString),
                "action": .string("savepoint")
            ])
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.contains("rollback") == true)
    }

    @Test("stop_server_session only accepts cancel or kill")
    func stopServerSessionModes() async throws {
        #expect(StopServerSessionTool.requiredScopes == [.toolsWrite])

        let result = try await call(
            StopServerSessionTool(),
            .object([
                "connection_id": .string(UUID().uuidString),
                "process_id": .string("42"),
                "mode": .string("terminate")
            ])
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.contains("cancel"))
        #expect(text.contains("kill"))
    }

    @Test("list_routines only accepts procedure or function")
    func listRoutinesKinds() async throws {
        let result = try await call(
            ListRoutinesTool(),
            .object([
                "connection_id": .string(UUID().uuidString),
                "kind": .string("trigger")
            ])
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.contains("procedure"))
        #expect(text.contains("function"))
    }

    @Test("search_schema needs a term and bounds its limit")
    func searchSchemaArguments() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(
                SearchSchemaTool(),
                .object(["connection_id": .string(UUID().uuidString)])
            )
        }

        let overLimit = try await call(
            SearchSchemaTool(),
            .object([
                "connection_id": .string(UUID().uuidString),
                "term": .string("user"),
                "limit": .int(5_000)
            ])
        )
        #expect(overLimit.isError)
        #expect(MCPToolTestHarness.errorText(overLimit)?.contains("500") == true)

        let emptyTerm = try await call(
            SearchSchemaTool(),
            .object([
                "connection_id": .string(UUID().uuidString),
                "term": .string("  ")
            ])
        )
        #expect(emptyTerm.isError)
    }

    @Test("run_maintenance needs an operation name")
    func runMaintenanceNeedsAnOperation() async throws {
        #expect(RunMaintenanceTool.requiredScopes == [.toolsWrite])
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(
                RunMaintenanceTool(),
                .object(["connection_id": .string(UUID().uuidString)])
            )
        }
    }

    @Test("get_server_dashboard only accepts the panels it declares")
    func serverDashboardPanels() {
        #expect(ServerDashboardTool.name == "get_server_dashboard")
        #expect(ServerDashboardTool.requiredScopes == [.toolsRead])
        #expect(ServerDashboardTool.panelNames == ["sessions", "metrics", "slow_queries"])
        let items = ServerDashboardTool.inputSchema["properties"]?["panels"]?["items"]
        #expect(items?["enum"]?.arrayValue?.compactMap(\.stringValue) == ServerDashboardTool.panelNames)
    }

    @Test("create_database is a write and describe_create_database_options is a read")
    func lifecycleScopes() {
        #expect(CreateDatabaseTool.requiredScopes == [.toolsWrite])
        #expect(DescribeCreateDatabaseOptionsTool.requiredScopes == [.toolsRead])
        #expect(DescribeCreateDatabaseOptionsTool.annotations.readOnlyHint == true)
    }

    @Test("explain_query takes a boolean analyze flag and reports a wrong type")
    func explainAnalyzeFlagIsTyped() async throws {
        #expect(ExplainQueryTool.requiredScopes == [.toolsRead])
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(
                ExplainQueryTool(),
                .object([
                    "connection_id": .string(UUID().uuidString),
                    "query": .string("SELECT 1"),
                    "analyze": .string("true")
                ])
            )
        }
    }

    @Test("list_indexes and list_foreign_keys accept an optional table, not a required one")
    func schemaObjectListingsAcceptAnOptionalTable() {
        for schema in [ListIndexesTool.inputSchema, ListForeignKeysTool.inputSchema] {
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(required == ["connection_id"])
            #expect(schema["properties"]?["table"] != nil)
        }
    }
}
