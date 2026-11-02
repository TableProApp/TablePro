//
//  MCPApprovedOperationTests.swift
//  TableProTests
//
//  What a person approves over MCP is the operation that runs: its database and schema, every statement with its
//  values, and a read that Safe Mode asks about like any other.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @MainActor
    struct MCPApprovedOperationTests {
        private func rig(
            type: DatabaseType = .postgresql,
            safeMode: SafeModeLevel,
            answer: WritePolicyPrompts.Answer = .approveAll,
            executionGate: (any ExecutionGate)? = nil
        ) -> WritePolicyRig {
            WritePolicyRig(
                connection: WritePolicyRig.connection(
                    type: type,
                    externalAccess: .readWrite,
                    aiPolicy: .alwaysAllow,
                    safeMode: safeMode
                ),
                prompts: WritePolicyPrompts(answer),
                live: true,
                executionGate: executionGate
            )
        }

        private func confirmingGate(_ sheet: StubConfirming, level: SafeModeLevel) -> DefaultExecutionGate {
            DefaultExecutionGate(
                confirming: sheet,
                authenticating: StubAuthenticating(answer: true),
                safeModeLevelResolver: { _ in level },
                forcesWriteResolver: { _ in false },
                auditLog: WritePolicyAuditLog()
            )
        }

        private func handle(
            _ tool: String,
            _ arguments: [String: JsonValue],
            on rig: WritePolicyRig,
            scopes: Set<MCPScope> = MCPScope.readWriteSet
        ) async throws -> MCPResult {
            var fields = arguments
            fields["connection_id"] = .string(rig.connection.id.uuidString)
            let params = MCPToolTestHarness.toolCallParams(name: tool, arguments: .object(fields))
            let handler = ToolsCallHandler(services: MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: rig.authPolicy,
                settingsProvider: { MCPSettings() },
                queryHistoryManager: ToolTestQueryHistoryStore()
            ))
            return try await handler.handle(
                params: params,
                context: MCPToolTestHarness.context(params: params, principal: MCPToolTestHarness.principal(scopes: scopes))
            )
        }

        private static func errorText(_ result: MCPResult) -> String {
            result.payload["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        }

        // MARK: - The scope a statement runs in

        struct ScopedCall: Sendable, CustomTestStringConvertible {
            let tool: String
            let type: DatabaseType
            let arguments: [String: JsonValue]
            let scopes: Set<MCPScope>
            let shown: String

            var testDescription: String { tool }
        }

        nonisolated private static let scopedCalls = [
            ScopedCall(
                tool: ExecuteQueryTool.name,
                type: .postgresql,
                arguments: ["query": .string("DELETE FROM orders WHERE total >= 0")],
                scopes: MCPScope.readWriteSet,
                shown: "DELETE FROM orders WHERE total >= 0"
            ),
            ScopedCall(
                tool: ConfirmDestructiveOperationTool.name,
                type: .postgresql,
                arguments: ["query": .string("DROP TABLE orders")],
                scopes: MCPScope.fullAccessSet,
                shown: "DROP TABLE orders"
            ),
            ScopedCall(
                tool: ExplainQueryTool.name,
                type: .cockroachdb,
                arguments: ["query": .string("UPDATE orders SET total = 0 WHERE id = 1"), "analyze": .bool(true)],
                scopes: MCPScope.readWriteSet,
                shown: "UPDATE orders SET total = 0 WHERE id = 1"
            )
        ]

        @Test("The confirmation names the database and schema the client picked", arguments: scopedCalls)
        func confirmationNamesTheScope(call: ScopedCall) async throws {
            let sheet = StubConfirming(answer: false)
            let rig = rig(type: call.type, safeMode: .alert, executionGate: confirmingGate(sheet, level: .alert))
            defer { rig.tearDown() }

            let result = try await handle(
                call.tool,
                call.arguments.merging(["database": .string("production"), "schema": .string("sales")]) { first, _ in first },
                on: rig,
                scopes: call.scopes
            )

            let request = try #require(sheet.lastRequest)
            #expect(request.scope?.database == "production")
            #expect(request.scope?.schema == "sales")
            let subtitle = OperationConfirmationPrompt.subtitle(of: request)
            #expect(subtitle.contains("production"))
            #expect(subtitle.contains("sales"))
            #expect(OperationConfirmationPrompt.statements(of: request).contains { $0.contains(call.shown) })
            #expect(result.payload["isError"]?.boolValue == true)
            #expect(rig.driver.received.isEmpty)
        }

        @Test("The approval an eliciting client is sent names the database and schema")
        func elicitationNamesTheScope() async throws {
            let rig = rig(safeMode: .alert, executionGate: RequestRecordingGate(allows: false))
            defer { rig.tearDown() }
            let arguments: JsonValue = .object([
                "connection_id": .string(rig.connection.id.uuidString),
                "query": .string("DELETE FROM orders WHERE total >= 0"),
                "database": .string("production"),
                "schema": .string("sales")
            ])
            let params = MCPToolTestHarness.toolCallParams(name: ExecuteQueryTool.name, arguments: arguments)
            let context = MCPToolTestHarness.context(
                params: params,
                principal: MCPToolTestHarness.principal(scopes: MCPScope.fullAccessSet),
                clientCapabilities: MCPToolTestHarness.elicitingClient()
            )

            do {
                _ = try await ExecuteQueryTool().call(
                    arguments: arguments,
                    context: context,
                    services: MCPToolServices(
                        connectionBridge: MCPConnectionBridge(),
                        authPolicy: rig.authPolicy,
                        settingsProvider: { MCPSettings() },
                        queryHistoryManager: ToolTestQueryHistoryStore()
                    )
                )
                Issue.record("Expected the approval to be elicited")
            } catch let signal as MCPInputRequired {
                let message = signal.inputRequests.first?.message ?? ""
                #expect(message.contains("'production'"))
                #expect(message.contains("'sales'"))
            }
            #expect(rig.driver.received.isEmpty)
        }

        // MARK: - insert_rows

        @Test("insert_rows shows each row with its values, and runs the statement it showed")
        func insertRowsShowsTheValuesItRuns() async throws {
            let sheet = StubConfirming(answer: true)
            let rig = rig(safeMode: .alert, executionGate: confirmingGate(sheet, level: .alert))
            defer { rig.tearDown() }

            let result = try await handle(
                InsertRowsTool.name,
                [
                    "table": .string("staff"),
                    "columns": .array([.string("email"), .string("role")]),
                    "rows": .array([.array([.string("mallory@attacker.example"), .string("admin")])])
                ],
                on: rig
            )

            #expect(result.payload["isError"]?.boolValue != true, "\(Self.errorText(result))")
            let request = try #require(sheet.lastRequest)
            let shown = OperationConfirmationPrompt.statements(of: request)
            #expect(shown.count == 1)
            #expect(shown.first?.contains("'mallory@attacker.example'") == true)
            #expect(shown.first?.contains("'admin'") == true)
            #expect(!(shown.first?.contains("…") ?? true))
            let approved = try #require(request.sql)
            #expect(rig.driver.received.filter { $0.hasPrefix("INSERT") } == [approved])
            #expect(rig.driver.receivedParameters == [[.text("mallory@attacker.example"), .text("admin")]])
        }

        // MARK: - Reads Safe Mode confirms

        @Test(
            "browse_table and count_rows ask Safe Mode as a read and stop when it says no",
            arguments: [BrowseTableTool.name, CountRowsTool.name]
        )
        func rowReadsAskTheGate(tool: String) async throws {
            let gate = RequestRecordingGate(allows: false)
            let rig = rig(type: .duckdb, safeMode: .alertFull, executionGate: gate)
            defer { rig.tearDown() }
            rig.driver.columns = [PluginColumnInfo(name: "id", dataType: "INTEGER")]

            let result = try await handle(tool, ["table": .string("salaries")], on: rig, scopes: MCPScope.readOnlySet)

            let requests = await gate.requests
            #expect(requests.count == 1)
            #expect(requests.first?.kind == .readQuery)
            #expect(requests.first?.scope?.connectionId == rig.connection.id)
            #expect(Self.errorText(result).hasPrefix("\(MCPToolErrorCode.denied.rawValue):"))
            #expect(rig.driver.received.isEmpty)
        }

        @Test(
            "browse_table and count_rows are confirmed at a level that confirms every query",
            arguments: [BrowseTableTool.name, CountRowsTool.name]
        )
        func rowReadsAreConfirmed(tool: String) async throws {
            let rig = rig(type: .duckdb, safeMode: .alertFull, answer: .refuseAll)
            defer { rig.tearDown() }
            rig.driver.columns = [PluginColumnInfo(name: "id", dataType: "INTEGER")]

            let result = try await handle(tool, ["table": .string("salaries")], on: rig, scopes: MCPScope.readOnlySet)

            #expect(rig.prompts.prompts == [.confirmation])
            #expect(Self.errorText(result).hasPrefix("\(MCPToolErrorCode.denied.rawValue):"))
            #expect(rig.driver.received.isEmpty)
        }
    }
}
