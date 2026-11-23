//
//  MCPConsentTargetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

extension GlobalStateSuites {
    // An elicited approval names a database and schema, and the client answers in a later request. A switch made in
    // between, or a name the call left out, resolves anew; the old answer must not run the statement there.
    @MainActor
    struct MCPConsentTargetTests {
        private static let approved: JsonValue = .object([
            "approve_statement": .object(["action": .string("accept"), "content": .object(["approved": .bool(true)])])
        ])

        private func rig(safeMode: SafeModeLevel = .silent, type: DatabaseType = .postgresql) -> WritePolicyRig {
            var connection = WritePolicyRig.connection(
                type: type,
                externalAccess: .readWrite,
                aiPolicy: .alwaysAllow,
                safeMode: safeMode
            )
            connection.database = "staging"
            return WritePolicyRig(connection: connection, prompts: WritePolicyPrompts(.approveAll), live: true)
        }

        private func call(
            _ tool: String,
            _ arguments: JsonValue,
            on rig: WritePolicyRig,
            answering state: String? = nil
        ) async throws -> MCPToolCallResult {
            var params: [String: JsonValue] = ["name": .string(tool), "arguments": arguments]
            if let state {
                params["requestState"] = .string(state)
                params["inputResponses"] = Self.approved
            }
            let context = MCPToolTestHarness.context(
                params: .object(params),
                principal: MCPToolTestHarness.principal(scopes: MCPScope.fullAccessSet),
                clientCapabilities: MCPToolTestHarness.elicitingClient()
            )
            let services = MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: rig.authPolicy,
                settingsProvider: { MCPSettings() },
                queryHistoryManager: ToolTestQueryHistoryStore()
            )
            guard let implementation = MCPToolRegistry.tool(named: tool) else {
                throw MCPToolExecutionError.invalidArgument("No tool \(tool)")
            }
            return try await implementation.call(arguments: arguments, context: context, services: services)
        }

        private func elicitation(
            _ tool: String,
            _ arguments: JsonValue,
            on rig: WritePolicyRig,
            answering state: String? = nil
        ) async throws -> MCPInputRequired? {
            do {
                _ = try await call(tool, arguments, on: rig, answering: state)
                return nil
            } catch let signal as MCPInputRequired {
                return signal
            }
        }

        private func dropOrders(_ rig: WritePolicyRig) -> JsonValue {
            .object([
                "connection_id": .string(rig.connection.id.uuidString),
                "query": .string("DROP TABLE orders")
            ])
        }

        @Test("An approval given while the connection browsed staging is asked again once it browses production")
        func databaseSwitchAfterApprovalAsksAgain() async throws {
            let rig = rig()
            defer { rig.tearDown() }
            let tool = ConfirmDestructiveOperationTool.name

            let first = try #require(try await elicitation(tool, dropOrders(rig), on: rig))
            #expect(first.inputRequests.first?.message.contains("'staging'") == true)
            let state = try #require(first.requestState)

            DatabaseManager.shared.updateSession(rig.connection.id) { $0.browseDatabase = "production" }
            let second = try #require(try await elicitation(tool, dropOrders(rig), on: rig, answering: state))

            #expect(second.inputRequests.first?.message.contains("'production'") == true)
            #expect(rig.driver.received.isEmpty)
        }

        @Test("An approval given on one schema is asked again once the connection browses another")
        func schemaSwitchAfterApprovalAsksAgain() async throws {
            let rig = rig()
            defer { rig.tearDown() }
            let tool = ConfirmDestructiveOperationTool.name
            DatabaseManager.shared.updateSession(rig.connection.id) { $0.browseSchema = "archive" }

            let first = try #require(try await elicitation(tool, dropOrders(rig), on: rig))
            #expect(first.inputRequests.first?.message.contains("'archive'") == true)
            let state = try #require(first.requestState)

            DatabaseManager.shared.updateSession(rig.connection.id) { $0.browseSchema = "public" }
            let second = try #require(try await elicitation(tool, dropOrders(rig), on: rig, answering: state))

            #expect(second.inputRequests.first?.message.contains("'public'") == true)
            #expect(rig.driver.received.isEmpty)
        }

        @Test("execute_query's elicited write is bound the same way")
        func executeQueryWriteIsBound() async throws {
            let rig = rig(safeMode: .alert)
            defer { rig.tearDown() }
            let tool = ExecuteQueryTool.name
            let arguments: JsonValue = .object([
                "connection_id": .string(rig.connection.id.uuidString),
                "query": .string("DELETE FROM orders WHERE total >= 0")
            ])

            let first = try #require(try await elicitation(tool, arguments, on: rig))
            let state = try #require(first.requestState)

            DatabaseManager.shared.updateSession(rig.connection.id) { $0.browseDatabase = "production" }
            let second = try await elicitation(tool, arguments, on: rig, answering: state)

            #expect(second != nil)
            #expect(rig.driver.received.isEmpty)
        }

        @Test("An approval for an unchanged target still runs the statement it named")
        func unchangedTargetRuns() async throws {
            let rig = rig()
            defer { rig.tearDown() }
            let tool = ConfirmDestructiveOperationTool.name

            let first = try #require(try await elicitation(tool, dropOrders(rig), on: rig))
            let state = try #require(first.requestState)
            let result = try await call(tool, dropOrders(rig), on: rig, answering: state)

            #expect(!result.isError)
            #expect(rig.driver.received.contains { $0.contains("DROP TABLE orders") })
        }

        @Test(
            "A two-table export asks once, listing both statements, and the approval runs both",
            arguments: [SafeModeLevel.alertFull, .safeModeFull]
        )
        func twoTableExportFinishes(level: SafeModeLevel) async throws {
            let rig = rig(safeMode: level)
            defer { rig.tearDown() }
            let tool = ExportDataTool.name
            let arguments: JsonValue = .object([
                "connection_id": .string(rig.connection.id.uuidString),
                "format": .string("csv"),
                "tables": .array([.string("orders"), .string("customers")])
            ])

            let first = try #require(try await elicitation(tool, arguments, on: rig))
            let detail = first.inputRequests.first?.fields.first?.description ?? ""
            #expect(first.inputRequests.count == 1)
            #expect(detail.contains("orders") && detail.contains("customers"))
            let state = try #require(first.requestState)
            let result = try await call(tool, arguments, on: rig, answering: state)

            #expect(!result.isError)
            #expect(rig.driver.received.filter { $0.contains("orders") }.count == 1)
            #expect(rig.driver.received.filter { $0.contains("customers") }.count == 1)
        }

        @Test("On SQL Server the elicitation names no schema, since the statement runs unqualified")
        func sqlServerElicitationNamesNoSchema() async throws {
            let rig = rig(safeMode: .alert, type: .mssql)
            defer { rig.tearDown() }
            DatabaseManager.shared.updateSession(rig.connection.id) { $0.browseSchema = "archive" }
            let arguments: JsonValue = .object([
                "connection_id": .string(rig.connection.id.uuidString),
                "query": .string("DELETE FROM orders WHERE id = 1")
            ])

            let asked = try #require(try await elicitation(ExecuteQueryTool.name, arguments, on: rig))
            let message = asked.inputRequests.first?.message ?? ""

            #expect(message.contains("'staging'"))
            #expect(!message.contains("archive"))
            #expect(!message.contains("schema"))
        }

        private func ran(_ tool: String, _ arguments: JsonValue, on rig: WritePolicyRig, answering state: String) async -> Bool {
            (try? await call(tool, arguments, on: rig, answering: state)).map { !$0.isError } ?? false
        }

        @Test("An accepted approval runs once, and sending its state again is refused")
        func replayedApprovalIsRefused() async throws {
            let rig = rig()
            defer { rig.tearDown() }
            let tool = ConfirmDestructiveOperationTool.name
            let state = try #require(try await elicitation(tool, dropOrders(rig), on: rig)?.requestState)

            _ = try await call(tool, dropOrders(rig), on: rig, answering: state)
            await #expect(throws: MCPProtocolError.self) {
                _ = try await call(tool, dropOrders(rig), on: rig, answering: state)
            }

            #expect(rig.driver.received.filter { $0.contains("DROP TABLE orders") }.count == 1)
        }

        @Test("Two submissions of one approval at once run the statement exactly once")
        func concurrentSubmissionsRunOnce() async throws {
            let rig = rig()
            defer { rig.tearDown() }
            let tool = ConfirmDestructiveOperationTool.name
            let state = try #require(try await elicitation(tool, dropOrders(rig), on: rig)?.requestState)

            let one = Task { await ran(tool, dropOrders(rig), on: rig, answering: state) }
            let two = Task { await ran(tool, dropOrders(rig), on: rig, answering: state) }
            let outcomes = [await one.value, await two.value]

            #expect(outcomes.filter { $0 }.count == 1)
            #expect(rig.driver.received.filter { $0.contains("DROP TABLE orders") }.count == 1)
        }
    }
}
