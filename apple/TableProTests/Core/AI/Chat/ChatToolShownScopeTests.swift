//
//  ChatToolShownScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProTestSupport
import Testing

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

// The card names where a call runs and the user clicks Run later; a database or schema switch in between must not
// move the call.
@MainActor
struct ChatToolShownScopeTests {
    private func session(database: String) -> ScriptAnsweringDriver {
        var connection = TestFixtures.makeConnection(database: database, type: .postgresql)
        connection.aiPolicy = .alwaysAllow
        let driver = ScriptAnsweringDriver(connection: connection) { _ in .empty }
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return driver
    }

    private func context(_ driver: ScriptAnsweringDriver, gate: any ExecutionGate, shown: DatabaseScope) -> ChatToolContext {
        ChatToolContext(
            connectionId: driver.connection.id,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: DiscardingHistory(),
                executionGate: gate
            ),
            chatMode: .agent,
            sessionId: UUID(),
            approvalWasExplicit: true,
            shownTarget: ChatRunTarget(
                scope: shown,
                driverGeneration: DatabaseManager.shared.session(for: shown.connectionId)?.driverGeneration
            ),
            policyLookup: { _ in .alwaysAllow }
        )
    }

    private static let dropOrders: JsonValue = .object([
        "query": .string("DROP TABLE orders"),
        "confirmation_phrase": .string(ConfirmDestructiveOperationChatTool.requiredPhrase)
    ])

    @Test("A call approved on staging runs on staging after the connection moved to production")
    func runsInTheShownDatabase() async throws {
        let driver = session(database: "staging")
        let id = driver.connection.id
        defer { DatabaseManager.shared.removeSession(for: id) }
        let gate = RequestRecordingGate(allows: false)
        let shown = DatabaseScope(connectionId: id, database: "staging", schema: nil)

        DatabaseManager.shared.updateSession(id) { $0.browseDatabase = "production" }
        await #expect(throws: (any Error).self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: Self.dropOrders, context: context(driver, gate: gate, shown: shown)
            )
        }

        let request = try #require(await gate.requests.first)
        #expect(request.scope?.database == "staging")
    }

    @Test("A call approved on schema archive runs on archive after the connection moved to public")
    func runsInTheShownSchema() async throws {
        let driver = session(database: "staging")
        let id = driver.connection.id
        defer { DatabaseManager.shared.removeSession(for: id) }
        let gate = RequestRecordingGate(allows: false)
        let shown = DatabaseScope(connectionId: id, database: "staging", schema: "archive")

        DatabaseManager.shared.updateSession(id) { $0.browseSchema = "public" }
        await #expect(throws: (any Error).self) {
            _ = try await ExecuteQueryChatTool().execute(
                input: .object(["query": .string("DELETE FROM orders WHERE id = 1")]),
                context: context(driver, gate: gate, shown: shown)
            )
        }

        let request = try #require(await gate.requests.first)
        #expect(request.scope?.database == "staging")
        #expect(request.scope?.schema == "archive")
    }

    @Test("A call approved on its card is refused once the connection reconnected, before any dialog")
    func reconnectAfterTheCardRefuses() async throws {
        let driver = session(database: "staging")
        let id = driver.connection.id
        defer { DatabaseManager.shared.removeSession(for: id) }
        let gate = RequestRecordingGate(allows: true)
        let approved = context(driver, gate: gate, shown: DatabaseScope(connectionId: id, database: "staging", schema: nil))

        let reconnected = ScriptAnsweringDriver(connection: driver.connection) { _ in .empty }
        DatabaseManager.shared.updateSession(id) { $0.install(reconnected, openedDatabase: nil) }
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(input: Self.dropOrders, context: approved)
        }

        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
        #expect(await gate.requests.isEmpty)
    }

    @Test("The card resolves its scope when it is drawn, and the Run click carries that scope to the call")
    func cardPinsItsScope() async throws {
        let driver = session(database: "staging")
        let id = driver.connection.id
        defer { DatabaseManager.shared.removeSession(for: id) }
        let registry = ChatToolRegistry()
        registry.registerBuiltIn(ConfirmDestructiveOperationChatTool())
        let viewModel = AIChatViewModel()
        viewModel.connection = driver.connection
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        let call = ToolUseBlock(id: "call_1", name: ConfirmDestructiveOperationChatTool().name, input: Self.dropOrders)
        let sessionId = viewModel.sessionId

        let approvals = Task {
            await viewModel.resolveAndAwaitApprovals(assembledBlocks: [call], assistantID: assistant.id, registry: registry)
        }
        try await waitUntil { ToolApprovalCenter.shared.isAwaiting(sessionId: sessionId, toolUseId: "call_1") }
        let drawn = ToolApprovalCenter.shared.shownScope(sessionId: sessionId, toolUseId: "call_1")
        DatabaseManager.shared.updateSession(id) { $0.browseDatabase = "production" }
        ToolApprovalCenter.shared.resolve(sessionId: sessionId, toolUseId: "call_1", decision: .run)
        let resolved = await approvals.value

        #expect(drawn?.database == "staging")
        #expect(resolved.explicitlyApproved == ["call_1"])
        #expect(resolved.shownTargets["call_1"]?.scope.database == "staging")
    }

    // Saved as staging, signed in to production; `reported` is what the connect captured from the driver.
    private func bigQuerySession(reported: String?) -> UUID {
        var connection = TestFixtures.makeConnection(database: "staging", type: .bigQuery)
        connection.aiPolicy = .alwaysAllow
        connection.additionalFields["bqProjectId"] = "production"
        var session = ConnectionSession(connection: connection)
        session.driver = ScriptAnsweringDriver(connection: connection) { _ in .empty }
        session.openedDatabase = reported
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection.id
    }

    private func drawnScope(on id: UUID) async throws -> DatabaseScope? {
        let registry = ChatToolRegistry()
        registry.registerBuiltIn(ConfirmDestructiveOperationChatTool())
        let viewModel = AIChatViewModel()
        viewModel.connection = DatabaseManager.shared.session(for: id)?.connection
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        let call = ToolUseBlock(id: "call_1", name: ConfirmDestructiveOperationChatTool().name, input: Self.dropOrders)
        let sessionId = viewModel.sessionId

        let approvals = Task {
            await viewModel.resolveAndAwaitApprovals(assembledBlocks: [call], assistantID: assistant.id, registry: registry)
        }
        try await waitUntil { ToolApprovalCenter.shared.isAwaiting(sessionId: sessionId, toolUseId: "call_1") }
        let drawn = ToolApprovalCenter.shared.shownScope(sessionId: sessionId, toolUseId: "call_1")
        ToolApprovalCenter.shared.resolve(sessionId: sessionId, toolUseId: "call_1", decision: .cancel)
        _ = await approvals.value
        return drawn
    }

    @Test("The card for BigQuery whose driver reported no project names no database")
    func bigQueryCardWithNoReportNamesNoDatabase() async throws {
        let id = bigQuerySession(reported: nil)
        defer { DatabaseManager.shared.removeSession(for: id) }

        let drawn = try await drawnScope(on: id)

        #expect(drawn != nil && drawn?.database == "")
    }

    @Test("The card for BigQuery names the project its driver reported, not the saved database")
    func bigQueryCardNamesTheReportedProject() async throws {
        let id = bigQuerySession(reported: "production")
        defer { DatabaseManager.shared.removeSession(for: id) }

        let drawn = try await drawnScope(on: id)

        #expect(drawn?.database == "production")
    }
}
