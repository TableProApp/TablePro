//
//  AIChatStoppedWriteTests.swift
//  TableProTests
//
//  Stop pressed while the assistant's write is in the driver: the write runs to its end, so the transcript must not
//  read as a failure the model would retry.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct AIChatStoppedWriteTests {
    private final class OneToolRoundTransport: ChatTransport, @unchecked Sendable {
        private let toolName: String

        init(toolName: String) {
            self.toolName = toolName
        }

        func streamChat(
            turns: [ChatTurnWire],
            options: ChatTransportOptions
        ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            let events: [ChatStreamEvent] = [
                .toolUseStart(id: "call_1", name: toolName, providerMetadata: nil),
                .toolUseDelta(id: "call_1", inputJSONDelta: "{}"),
                .toolUseEnd(id: "call_1")
            ]
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func fetchAvailableModels() async throws -> [AIModelInfo] { [] }

        func testConnection() async throws -> Bool { true }
    }

    // The assistant's own execute_query, on a connection the test controls.
    private struct WriteThroughExecuteQuery: ChatTool {
        let name = "write_rows"
        let mode: ChatToolMode = .readOnly
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])
        let target: ChatToolContext

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            try await ExecuteQueryChatTool().execute(
                input: .object(["query": .string("UPDATE orders SET n = n + 1 WHERE id = 1")]),
                context: target
            )
        }
    }

    private static let settings = AISettings(
        enabled: true,
        includeSchema: false,
        includeCurrentQuery: false,
        includeQueryResults: false,
        maxToolRoundtrips: AISettings.defaultMaxToolRoundtrips,
        maxToolRoundtripsEnabled: false,
        chatMode: .agent
    )

    @Test("Stop during a write in the driver leaves a result saying it may have been applied, and history keeps the write")
    func stopDuringWriteSaysItMayHaveBeenApplied() async throws {
        let gate = AsyncGate()
        let driver = AnsweringPluginDriver(hold: gate)
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }
        let history = RecordingQueryHistory()
        let tool = WriteThroughExecuteQuery(target: ChatToolContext(
            connectionId: scope.connectionId,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: history,
                executionGate: AlwaysAllowGate()
            ),
            chatMode: .agent,
            policyLookup: { _ in .alwaysAllow }
        ))
        let registry = ChatToolRegistry()
        registry.register(tool)
        let viewModel = AIChatViewModel()
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        viewModel.streamingState = .streaming(assistantID: assistant.id)
        viewModel.runStream(
            chatMessages: [],
            promptContext: nil,
            resolved: AIProviderFactory.ResolvedProvider(
                provider: OneToolRoundTransport(toolName: tool.name),
                model: "test-model",
                config: AIProviderConfig(name: "Test", type: .claude)
            ),
            assistantID: assistant.id,
            settings: Self.settings,
            registry: registry
        )
        let task = viewModel.streamingTask
        await gate.arrived(1)

        viewModel.cancelStream()
        await task?.value

        let index = try #require(viewModel.messages.firstIndex { $0.id == assistant.id })
        try #require(index + 1 < viewModel.messages.count)
        let results = viewModel.messages[index + 1].blocks.compactMap { block -> ToolResultBlock? in
            guard case .toolResult(let result) = block.kind else { return nil }
            return result
        }
        #expect(results.map { $0.toolUseId } == ["call_1"])
        #expect(results.first?.isError == true)
        #expect(results.first?.content == "Error: \(DatabaseAccessBridge.stoppedWhileRunning.message)")
        #expect(history.requests.map { $0.wasSuccessful } == [false])
        #expect(driver.finishedCount == 0)

        await gate.open()
        try await waitUntil { driver.finishedCount == 1 }
    }
}
