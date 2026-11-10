import Foundation
import TableProMCP
import TableProPluginKit
import TableProTestSupport
@testable import TablePro
import Testing

struct ChatToolCallRepairTests {
    private func call(_ id: String) -> ChatContentBlockWire {
        .toolUse(ToolUseBlock(id: id, name: "execute_query", input: .object([:])))
    }

    private func result(_ id: String, _ content: String = "ok") -> ChatContentBlockWire {
        .toolResult(ToolResultBlock(toolUseId: id, content: content))
    }

    private func resultIds(_ turn: ChatTurnWire) -> [String] {
        turn.blocks.compactMap { block -> String? in
            guard case .toolResult(let result) = block.kind else { return nil }
            return result.toolUseId
        }
    }

    @Test("A transcript whose calls are all answered is sent as it is")
    func answeredTranscriptIsUntouched() {
        let turns = [
            ChatTurnWire(role: .user, blocks: [.text("count users")]),
            ChatTurnWire(role: .assistant, blocks: [call("a")]),
            ChatTurnWire(role: .user, blocks: [result("a")]),
            ChatTurnWire(role: .assistant, blocks: [.text("42")])
        ]

        #expect(ChatToolCallRepair.answeringEveryToolCall(turns) == turns)
    }

    @Test("An unanswered call followed by a new message gets a result turn between them")
    func unansweredCallBeforeNewMessage() {
        let turns = [
            ChatTurnWire(role: .user, blocks: [.text("count users")]),
            ChatTurnWire(role: .assistant, blocks: [call("a"), call("b")]),
            ChatTurnWire(role: .user, blocks: [.text("never mind")])
        ]

        let repaired = ChatToolCallRepair.answeringEveryToolCall(turns)

        #expect(repaired.count == 4)
        #expect(repaired[2].role == .user)
        #expect(resultIds(repaired[2]) == ["a", "b"])
        #expect(repaired[3] == turns[2])
    }

    @Test("An unanswered call at the end of the transcript gets a trailing result turn")
    func unansweredCallAtTheEnd() {
        let turns = [
            ChatTurnWire(role: .user, blocks: [.text("count users")]),
            ChatTurnWire(role: .assistant, blocks: [call("a")])
        ]

        let repaired = ChatToolCallRepair.answeringEveryToolCall(turns)

        #expect(repaired.count == 3)
        #expect(repaired[2].role == .user)
        #expect(resultIds(repaired[2]) == ["a"])
    }

    @Test("A partly answered round gets only the missing result, ahead of the real ones")
    func partlyAnsweredRound() {
        let turns = [
            ChatTurnWire(role: .assistant, blocks: [call("a"), call("b")]),
            ChatTurnWire(role: .user, blocks: [result("b")])
        ]

        let repaired = ChatToolCallRepair.answeringEveryToolCall(turns)

        #expect(repaired.count == 2)
        #expect(resultIds(repaired[1]) == ["a", "b"])
    }

    @Test("A result recorded beside its call in the same turn counts as an answer")
    func resultInTheSameTurn() {
        let turns = [
            ChatTurnWire(role: .assistant, blocks: [call("a"), result("a")]),
            ChatTurnWire(role: .user, blocks: [.text("thanks")])
        ]

        #expect(ChatToolCallRepair.answeringEveryToolCall(turns) == turns)
    }

    @Test("The synthetic result is marked as an error")
    func syntheticResultIsAnError() {
        let repaired = ChatToolCallRepair.answeringEveryToolCall([
            ChatTurnWire(role: .assistant, blocks: [call("a")])
        ])

        guard case .toolResult(let block) = repaired.last?.blocks.first?.kind else {
            Issue.record("expected a tool result")
            return
        }
        #expect(block.isError)
        #expect(block.content == ChatToolCallRepair.interruptedContent)
    }
}

@MainActor
struct AIChatStoppedToolRoundTests {
    private final class ScriptedTransport: ChatTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let rounds: [[ChatStreamEvent]]
        private var requests: [[ChatTurnWire]] = []

        init(rounds: [[ChatStreamEvent]]) {
            self.rounds = rounds
        }

        var requestedTurns: [[ChatTurnWire]] {
            lock.withLock { requests }
        }

        func streamChat(
            turns: [ChatTurnWire],
            options: ChatTransportOptions
        ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            let index = lock.withLock { () -> Int in
                requests.append(turns)
                return requests.count - 1
            }
            let events = index < rounds.count ? rounds[index] : [.textDelta("done")]
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

    private struct GatedTool: ChatTool {
        let name: String
        let mode: ChatToolMode
        let gate: AsyncGate
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            await gate.wait()
            return ChatToolResult(content: "3 rows changed", isError: false)
        }
    }

    private static func toolRound(id: String, name: String) -> [ChatStreamEvent] {
        [
            .toolUseStart(id: id, name: name, providerMetadata: nil),
            .toolUseDelta(id: id, inputJSONDelta: "{}"),
            .toolUseEnd(id: id)
        ]
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

    private func start(
        _ viewModel: AIChatViewModel,
        transport: ScriptedTransport,
        tool: GatedTool,
        chatMessages: [ChatTurnWire] = []
    ) -> ChatTurn {
        let registry = ChatToolRegistry()
        registry.register(tool)
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        viewModel.streamingState = .streaming(assistantID: assistant.id)
        viewModel.runStream(
            chatMessages: chatMessages,
            promptContext: nil,
            resolved: AIProviderFactory.ResolvedProvider(
                provider: transport,
                model: "test-model",
                config: AIProviderConfig(name: "Test", type: .claude)
            ),
            assistantID: assistant.id,
            settings: Self.settings,
            registry: registry
        )
        return assistant
    }

    private func turnAfter(_ turn: ChatTurn, in viewModel: AIChatViewModel) throws -> ChatTurn {
        let index = try #require(viewModel.messages.firstIndex { $0.id == turn.id })
        try #require(index + 1 < viewModel.messages.count)
        return viewModel.messages[index + 1]
    }

    private func toolResults(in turn: ChatTurn) -> [ToolResultBlock] {
        turn.blocks.compactMap { block -> ToolResultBlock? in
            guard case .toolResult(let result) = block.kind else { return nil }
            return result
        }
    }

    private func hasToolUse(_ turn: ChatTurn) -> Bool {
        turn.blocks.contains { block in
            if case .toolUse = block.kind { return true }
            return false
        }
    }

    @Test("Stop while a tool call waits for approval leaves a result for that call")
    func stopWhileAwaitingApproval() async throws {
        let transport = ScriptedTransport(rounds: [Self.toolRound(id: "call_1", name: "writer")])
        let viewModel = AIChatViewModel()
        let assistant = start(
            viewModel,
            transport: transport,
            tool: GatedTool(name: "writer", mode: .write, gate: AsyncGate())
        )
        let task = viewModel.streamingTask
        try await waitUntil { self.hasToolUse(assistant) }

        viewModel.cancelStream()
        await task?.value

        let following = try turnAfter(assistant, in: viewModel)
        let results = toolResults(in: following)
        #expect(results.map(\.toolUseId) == ["call_1"])
        #expect(results.first?.isError == true)
        #expect(following.role == .user)
    }

    @Test("Stop while a tool runs keeps the result of what ran")
    func stopWhileExecuting() async throws {
        let gate = AsyncGate()
        let transport = ScriptedTransport(rounds: [Self.toolRound(id: "call_1", name: "reader")])
        let viewModel = AIChatViewModel()
        let assistant = start(
            viewModel,
            transport: transport,
            tool: GatedTool(name: "reader", mode: .readOnly, gate: gate)
        )
        let task = viewModel.streamingTask
        await gate.arrived(1)

        viewModel.cancelStream()
        await gate.open()
        await task?.value

        let results = toolResults(in: try turnAfter(assistant, in: viewModel))
        #expect(results.map(\.toolUseId) == ["call_1"])
        #expect(results.first?.content == "3 rows changed")
        #expect(transport.requestedTurns.count == 1)
    }

    @Test("A saved transcript with an unanswered call is repaired before it is sent")
    func unansweredHistoryIsRepairedOnTheWire() async throws {
        let transport = ScriptedTransport(rounds: [[.textDelta("ok")]])
        let viewModel = AIChatViewModel()
        let history = [
            ChatTurnWire(role: .user, blocks: [.text("drop it")]),
            ChatTurnWire(role: .assistant, blocks: [
                .toolUse(ToolUseBlock(id: "call_9", name: "writer", input: .object([:])))
            ]),
            ChatTurnWire(role: .user, blocks: [.text("actually, count the rows")])
        ]
        _ = start(
            viewModel,
            transport: transport,
            tool: GatedTool(name: "writer", mode: .write, gate: AsyncGate()),
            chatMessages: history
        )
        await viewModel.streamingTask?.value

        let sent = transport.requestedTurns.first ?? []
        try #require(sent.count == 4)
        let answered = sent[2].blocks.compactMap { block -> String? in
            guard case .toolResult(let result) = block.kind else { return nil }
            return result.toolUseId
        }
        #expect(answered == ["call_9"])
    }
}
