//
//  AIChatViewModelToolLoopTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AIChatViewModel tool roundtrip loop", .serialized)
@MainActor
struct AIChatViewModelToolLoopTests {
    private static let testLimit = 5
    private final class ScriptedTransport: ChatTransport, @unchecked Sendable {
        private let rounds: [[ChatStreamEvent]]
        private(set) var roundsRequested = 0

        init(rounds: [[ChatStreamEvent]]) {
            self.rounds = rounds
        }

        func streamChat(
            turns: [ChatTurnWire],
            options: ChatTransportOptions
        ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            let index = roundsRequested
            roundsRequested += 1
            let events = index < rounds.count ? rounds[index] : [.textDelta("done")]
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func fetchAvailableModels() async throws -> [String] { [] }

        func testConnection() async throws -> Bool { true }
    }

    private struct NoopTool: ChatTool {
        let name = "noop"
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])
        let mode: ChatToolMode = .readOnly

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: "ok", isError: false)
        }
    }

    private static func toolRound(id: String) -> [ChatStreamEvent] {
        [
            .toolUseStart(id: id, name: "noop", providerMetadata: nil),
            .toolUseDelta(id: id, inputJSONDelta: "{}"),
            .toolUseEnd(id: id)
        ]
    }

    private static func toolRounds(count: Int) -> [[ChatStreamEvent]] {
        (1...count).map { toolRound(id: "u\($0)") }
    }

    private static func makeSettings(limit: Int?, enabled: Bool) -> AISettings {
        AISettings(
            enabled: true,
            includeSchema: false,
            includeCurrentQuery: false,
            includeQueryResults: false,
            maxToolRoundtrips: limit ?? AISettings.defaultMaxToolRoundtrips,
            maxToolRoundtripsEnabled: enabled,
            chatMode: .agent
        )
    }

    private static func makeResolved(_ transport: ChatTransport) -> AIProviderFactory.ResolvedProvider {
        AIProviderFactory.ResolvedProvider(
            provider: transport,
            model: "test-model",
            config: AIProviderConfig(name: "Test", type: .claude)
        )
    }

    private func runLoop(
        viewModel: AIChatViewModel,
        transport: ChatTransport,
        settings: AISettings
    ) async {
        let registry = ChatToolRegistry()
        registry.register(NoopTool())
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        viewModel.streamingState = .streaming(assistantID: assistant.id)
        viewModel.runStream(
            chatMessages: [],
            promptContext: nil,
            resolved: Self.makeResolved(transport),
            assistantID: assistant.id,
            settings: settings,
            registry: registry
        )
        await viewModel.streamingTask?.value
    }

    private func toolUseTurnCount(_ viewModel: AIChatViewModel) -> Int {
        viewModel.messages.filter { turn in
            turn.blocks.contains { block in
                if case .toolUse = block.kind { return true }
                return false
            }
        }.count
    }

    @Test("Pauses after exactly the configured number of executed rounds")
    func pausesAtConfiguredLimit() async {
        let transport = ScriptedTransport(rounds: Self.toolRounds(count: 20))
        let viewModel = AIChatViewModel()

        await runLoop(
            viewModel: viewModel,
            transport: transport,
            settings: Self.makeSettings(limit: Self.testLimit, enabled: true)
        )

        #expect(viewModel.isPausedAtToolLimit)
        #expect(viewModel.toolLimitPauseCount == Self.testLimit)
        #expect(toolUseTurnCount(viewModel) == Self.testLimit)
    }

    @Test("Does not stream a round it cannot execute")
    func doesNotWasteARound() async {
        let transport = ScriptedTransport(rounds: Self.toolRounds(count: 20))
        let viewModel = AIChatViewModel()

        await runLoop(
            viewModel: viewModel,
            transport: transport,
            settings: Self.makeSettings(limit: Self.testLimit, enabled: true)
        )

        #expect(transport.roundsRequested == Self.testLimit)
    }

    @Test("Pausing leaves no error state and keeps the retry affordance hidden")
    func pauseIsNotAFailure() async {
        let transport = ScriptedTransport(rounds: Self.toolRounds(count: 20))
        let viewModel = AIChatViewModel()

        await runLoop(
            viewModel: viewModel,
            transport: transport,
            settings: Self.makeSettings(limit: Self.testLimit, enabled: true)
        )

        #expect(viewModel.isPausedAtToolLimit)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.lastMessageFailed == false)
        #expect(viewModel.isStreaming == false)
    }

    @Test("Pause preserves the transcript and ends on a tool result turn")
    func pausePreservesTranscript() async {
        let transport = ScriptedTransport(rounds: Self.toolRounds(count: 20))
        let viewModel = AIChatViewModel()

        await runLoop(
            viewModel: viewModel,
            transport: transport,
            settings: Self.makeSettings(limit: Self.testLimit, enabled: true)
        )

        #expect(viewModel.isPausedAtToolLimit)
        #expect(viewModel.messages.last?.role == .user)
        let trailingBlocks = viewModel.messages.last?.blocks ?? []
        #expect(!trailingBlocks.isEmpty)
        #expect(trailingBlocks.allSatisfy { block in
            if case .toolResult = block.kind { return true }
            return false
        })
        #expect(viewModel.messages.allSatisfy { !$0.blocks.isEmpty })
    }

    @Test("No limit runs until the model stops calling tools")
    func unlimitedRunsToCompletion() async {
        let transport = ScriptedTransport(rounds: Self.toolRounds(count: 3) + [[.textDelta("all done")]])
        let viewModel = AIChatViewModel()

        await runLoop(
            viewModel: viewModel,
            transport: transport,
            settings: Self.makeSettings(limit: Self.testLimit, enabled: false)
        )

        #expect(viewModel.isPausedAtToolLimit == false)
        #expect(toolUseTurnCount(viewModel) == 3)
        #expect(viewModel.messages.last?.plainText.contains("all done") == true)
    }

    @Test("Continue resumes from the pause with a fresh budget")
    func continueResumesFromPause() async {
        let transport = ScriptedTransport(rounds: Self.toolRounds(count: 20))
        let viewModel = AIChatViewModel()

        await runLoop(
            viewModel: viewModel,
            transport: transport,
            settings: Self.makeSettings(limit: Self.testLimit, enabled: true)
        )
        #expect(viewModel.isPausedAtToolLimit)
        let pausedMessageCount = viewModel.messages.count

        let resumeTransport = ScriptedTransport(rounds: [[.textDelta("finished")]])
        await runLoop(
            viewModel: viewModel,
            transport: resumeTransport,
            settings: Self.makeSettings(limit: Self.testLimit, enabled: true)
        )

        #expect(viewModel.isPausedAtToolLimit == false)
        #expect(viewModel.messages.count > pausedMessageCount)
        #expect(viewModel.messages.last?.plainText.contains("finished") == true)
    }

    @Test("continueToolLoop only acts while paused")
    func continueIsInertWhenNotPaused() {
        let viewModel = AIChatViewModel()
        viewModel.streamingState = .idle

        viewModel.continueToolLoop()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Restoring the last conversation never replaces messages already in the panel")
    func conversationRestoreDoesNotClobberInFlightMessages() async {
        let viewModel = AIChatViewModel()
        viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("typed first")]))

        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.plainText == "typed first")
    }
}
