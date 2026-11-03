//
//  DestructiveStatementRoutingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

struct DestructiveRoute: Sendable, CustomTestStringConvertible {
    let sql: String
    let destructive: Bool
    var databaseType: DatabaseType = .postgresql
    // What the driver is sent, when a script reaches it batch by batch.
    var driverReceives: String?

    var testDescription: String { sql }

    static let all: [DestructiveRoute] = [
        DestructiveRoute(sql: "DROP TABLE matrix_rows", destructive: true),
        DestructiveRoute(sql: "TRUNCATE matrix_rows", destructive: true),
        DestructiveRoute(sql: "DELETE FROM matrix_rows", destructive: true),
        DestructiveRoute(sql: "DELETE FROM matrix_rows WHERE id = 1", destructive: false),
        DestructiveRoute(sql: "UPDATE matrix_rows SET note = 'x'", destructive: false),
        DestructiveRoute(sql: "UPDATE matrix_rows SET note = 'x' WHERE id = 1", destructive: false),
        DestructiveRoute(
            sql: "DELETE FROM dbo.staging\nGO\nINSERT INTO dbo.staging SELECT * FROM dbo.src",
            destructive: true,
            databaseType: .mssql,
            driverReceives: "DELETE FROM dbo.staging"
        ),
        DestructiveRoute(
            sql: "DELETE FROM dbo.staging WHERE id = 1\nGO\nINSERT INTO dbo.staging SELECT * FROM dbo.src",
            destructive: false,
            databaseType: .mssql,
            driverReceives: "DELETE FROM dbo.staging WHERE id = 1"
        ),
    ]
}

extension GlobalStateSuites {
    // execute_query and confirm_destructive_operation split every statement between them, over MCP and in the chat.
    @MainActor
    struct DestructiveStatementRoutingTests {
        private struct Outcome {
            let ran: Bool
            let text: String
            let prompts: [WritePrompt]
            let received: [String]
            let rowCaps: [Int?]
        }

        private struct Rig {
            let rig: WritePolicyRig
            let received: () -> [String]
            let rowCaps: () -> [Int?]
        }

        private static let unfilteredDelete = DestructiveRoute(sql: "DELETE FROM matrix_rows", destructive: true)

        private func makeRig(_ prompts: WritePolicyPrompts, _ databaseType: DatabaseType) -> Rig {
            let connection = WritePolicyRig.connection(
                type: databaseType,
                externalAccess: .readWrite,
                aiPolicy: .alwaysAllow,
                safeMode: .silent
            )
            guard databaseType == .mssql else {
                let rig = WritePolicyRig(connection: connection, prompts: prompts, live: true)
                return Rig(rig: rig, received: { rig.driver.received }, rowCaps: { [] })
            }
            let scripts = ScriptAnsweringDriver(connection: connection)
            let rig = WritePolicyRig(connection: connection, prompts: prompts, live: true, sessionDriver: scripts)
            return Rig(
                rig: rig,
                received: { scripts.sentBatches.map { $0.sql } + scripts.sentStatements },
                rowCaps: { scripts.sentBatches.map { $0.rowCap } }
            )
        }

        private func mcp(
            _ tool: String,
            _ route: DestructiveRoute,
            extra: [String: JsonValue] = [:],
            answer: WritePolicyPrompts.Answer = .approveAll
        ) async -> Outcome {
            let prompts = WritePolicyPrompts(answer)
            let setup = makeRig(prompts, route.databaseType)
            let rig = setup.rig
            defer { rig.tearDown() }
            let handler = ToolsCallHandler(services: MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: rig.authPolicy,
                settingsProvider: { MCPSettings() },
                queryHistoryManager: ToolTestQueryHistoryStore()
            ))
            let arguments: [String: JsonValue] = ["connection_id": .string(rig.connection.id.uuidString), "query": .string(route.sql)]
            let params = MCPToolTestHarness.toolCallParams(
                name: tool,
                arguments: .object(arguments.merging(extra) { first, _ in first })
            )
            let context = MCPToolTestHarness.context(
                params: params,
                principal: MCPToolTestHarness.principal(scopes: MCPTokenTier.fullAccess.scopes)
            )
            var ran = false
            var text: String
            do {
                let result = try await handler.handle(params: params, context: context)
                text = result.payload["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
                ran = result.payload["isError"]?.boolValue != true
            } catch {
                text = "\(error)"
            }
            return Outcome(
                ran: ran, text: text, prompts: prompts.prompts, received: setup.received(), rowCaps: setup.rowCaps()
            )
        }

        private func assistant(
            _ tool: any ChatTool,
            _ route: DestructiveRoute,
            answer: WritePolicyPrompts.Answer = .approveAll
        ) async -> Outcome {
            let prompts = WritePolicyPrompts(answer)
            let setup = makeRig(prompts, route.databaseType)
            let rig = setup.rig
            defer { rig.tearDown() }
            let context = ChatToolContext(
                connectionId: rig.connection.id,
                bridge: MCPConnectionBridge(),
                authPolicy: rig.authPolicy,
                sessionId: UUID(),
                policyLookup: { _ in .alwaysAllow }
            )
            var input: [String: JsonValue] = ["query": .string(route.sql)]
            if tool is ConfirmDestructiveOperationChatTool {
                input["confirmation_phrase"] = .string(ConfirmDestructiveOperationChatTool.requiredPhrase)
            }
            var ran = false
            var text: String
            do {
                let result = try await tool.execute(input: .object(input), context: context)
                text = result.content
                ran = !result.isError
            } catch {
                text = error.localizedDescription
            }
            return Outcome(
                ran: ran, text: text, prompts: prompts.prompts, received: setup.received(), rowCaps: setup.rowCaps()
            )
        }

        private func expectOneRoute(_ route: DestructiveRoute, query: Outcome, confirm: Outcome) {
            let (runs, refuses) = route.destructive ? (confirm, query) : (query, confirm)
            let sent = route.driverReceives ?? route.sql

            #expect(runs.ran, "\(runs.text)")
            #expect(runs.received.contains { $0.contains(sent) }, "\(runs.received)")
            #expect(runs.prompts == (route.destructive ? [.confirmation] : []))
            // A script's result sets keep their rows, as execute_query's do.
            #expect(runs.rowCaps.allSatisfy { ($0 ?? .max) > 1 }, "\(runs.rowCaps)")

            #expect(!refuses.ran)
            #expect(refuses.received.isEmpty)
            #expect(refuses.prompts.isEmpty)
            #expect(refuses.text.contains(route.destructive ? ConfirmDestructiveOperationTool.name : ExecuteQueryTool.name))
        }

        @Test("Over MCP each statement runs through exactly one of the two tools", arguments: DestructiveRoute.all)
        func mcpRoutesEachStatementOnce(route: DestructiveRoute) async {
            let query = await mcp(ExecuteQueryTool.name, route)
            let confirm = await mcp(ConfirmDestructiveOperationTool.name, route)

            expectOneRoute(route, query: query, confirm: confirm)
            let refusal = route.destructive ? query.text : confirm.text
            let code = route.destructive ? MCPToolErrorCode.denied : .invalidArgument
            #expect(refusal.hasPrefix("\(code.rawValue):"))
        }

        @Test("In the chat each statement runs through exactly one of the two tools", arguments: DestructiveRoute.all)
        func assistantRoutesEachStatementOnce(route: DestructiveRoute) async {
            let query = await assistant(ExecuteQueryChatTool(), route)
            let confirm = await assistant(ConfirmDestructiveOperationChatTool(), route)

            expectOneRoute(route, query: query, confirm: confirm)
        }

        @Test("An analyzed plan of a DELETE with no WHERE is refused before anything runs, and says why")
        func analyzedExplainOfUnfilteredDeleteIsRefused() async {
            let route = DestructiveRoute(sql: "DELETE FROM matrix_rows", destructive: true, databaseType: .cockroachdb)
            let outcome = await mcp(ExplainQueryTool.name, route, extra: ["analyze": .bool(true)])

            #expect(!outcome.ran)
            #expect(outcome.text.hasPrefix("\(MCPToolErrorCode.denied.rawValue):"))
            #expect(outcome.text.contains("without analyze"))
            #expect(outcome.prompts.isEmpty)
            #expect(outcome.received.isEmpty)
        }

        @Test("A DELETE with no WHERE the user declines never reaches the database")
        func declinedUnfilteredDeleteDoesNotRun() async {
            let overMCP = await mcp(ConfirmDestructiveOperationTool.name, Self.unfilteredDelete, answer: .refuseAll)
            let inChat = await assistant(ConfirmDestructiveOperationChatTool(), Self.unfilteredDelete, answer: .refuseAll)

            for outcome in [overMCP, inChat] {
                #expect(!outcome.ran)
                #expect(outcome.prompts == [.confirmation])
                #expect(outcome.received.isEmpty)
            }
        }
    }
}
