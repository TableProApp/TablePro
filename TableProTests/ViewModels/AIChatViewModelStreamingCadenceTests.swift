//
//  AIChatViewModelStreamingCadenceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AIChatViewModel streaming cadence", .serialized)
@MainActor
struct AIChatViewModelStreamingCadenceTests {
    private final class NeverTickingClock: StreamFlushClock, @unchecked Sendable {
        func sleep(for duration: Duration) async throws {
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    private final class UnfoldingTransport: ChatTransport, @unchecked Sendable {
        private let events: [ChatStreamEvent]
        private let beforeEach: @MainActor (Int) -> Void
        private var index = 0

        init(events: [ChatStreamEvent], beforeEach: @escaping @MainActor (Int) -> Void) {
            self.events = events
            self.beforeEach = beforeEach
        }

        func streamChat(
            turns: [ChatTurnWire],
            options: ChatTransportOptions
        ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { [self] in
                let current = index
                await MainActor.run { beforeEach(current) }
                guard current < events.count else { return nil }
                index += 1
                return events[current]
            }
        }

        func fetchAvailableModels() async throws -> [AIModelInfo] { [] }

        func testConnection() async throws -> Bool { true }
    }

    private struct StreamFailure: Error {}

    private final class FailingTransport: ChatTransport, @unchecked Sendable {
        private let events: [ChatStreamEvent]

        init(events: [ChatStreamEvent]) {
            self.events = events
        }

        func streamChat(
            turns: [ChatTurnWire],
            options: ChatTransportOptions
        ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish(throwing: StreamFailure())
            }
        }

        func fetchAvailableModels() async throws -> [AIModelInfo] { [] }

        func testConnection() async throws -> Bool { true }
    }

    private static func makeResolved(_ transport: ChatTransport) -> AIProviderFactory.ResolvedProvider {
        AIProviderFactory.ResolvedProvider(
            provider: transport,
            model: "test-model",
            config: AIProviderConfig(name: "Test", type: .claude)
        )
    }

    private static func makeSettings() -> AISettings {
        AISettings(
            enabled: true,
            includeSchema: false,
            includeCurrentQuery: false,
            includeQueryResults: false,
            chatMode: .ask
        )
    }

    private func runStream(
        viewModel: AIChatViewModel,
        transport: ChatTransport
    ) async -> ChatTurn {
        viewModel.chatMode = Self.makeSettings().chatMode
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        viewModel.streamingState = .streaming(assistantID: assistant.id)
        viewModel.runStream(
            chatMessages: [],
            promptContext: nil,
            resolved: Self.makeResolved(transport),
            assistantID: assistant.id,
            settings: Self.makeSettings(),
            registry: ChatToolRegistry()
        )
        await viewModel.streamingTask?.value
        return assistant
    }

    @Test("The first token is shown before the next event is consumed")
    func firstTokenIsFlushedImmediately() async {
        let viewModel = AIChatViewModel()
        viewModel.streamFlushClock = NeverTickingClock()
        var snapshots: [String] = []

        let transport = UnfoldingTransport(
            events: [.textDelta("Alpha"), .textDelta("Beta"), .textDelta("Gamma")]
        ) { [weak viewModel] _ in
            snapshots.append(viewModel?.messages.last?.plainText ?? "")
        }

        let assistant = await runStream(viewModel: viewModel, transport: transport)

        #expect(snapshots.first == "")
        #expect(snapshots.count >= 2)
        #expect(snapshots[1] == "Alpha")
        #expect(assistant.plainText == "AlphaBetaGamma")
    }

    @Test("Later tokens coalesce instead of updating on every event")
    func laterTokensAreCoalesced() async {
        let viewModel = AIChatViewModel()
        viewModel.streamFlushClock = NeverTickingClock()
        var snapshots: [String] = []

        let transport = UnfoldingTransport(
            events: [.textDelta("Alpha"), .textDelta("Beta"), .textDelta("Gamma"), .textDelta("Delta")]
        ) { [weak viewModel] _ in
            snapshots.append(viewModel?.messages.last?.plainText ?? "")
        }

        let assistant = await runStream(viewModel: viewModel, transport: transport)

        #expect(snapshots.dropFirst(2).allSatisfy { $0 == "Alpha" })
        #expect(assistant.plainText == "AlphaBetaGammaDelta")
    }

    @Test("Buffered text is never lost when the stream ends")
    func trailingTextIsAlwaysFlushed() async {
        let viewModel = AIChatViewModel()
        viewModel.streamFlushClock = NeverTickingClock()

        let transport = UnfoldingTransport(
            events: (1...50).map { .textDelta("chunk\($0) ") }
        ) { _ in }

        let assistant = await runStream(viewModel: viewModel, transport: transport)

        let expected = (1...50).map { "chunk\($0) " }.joined()
        #expect(assistant.plainText == expected)
    }

    @Test("Buffered text survives a stream that fails part way through")
    func bufferedTextSurvivesAStreamFailure() async {
        let viewModel = AIChatViewModel()
        viewModel.streamFlushClock = NeverTickingClock()

        let transport = FailingTransport(
            events: [.textDelta("kept one "), .textDelta("kept two")]
        )

        viewModel.chatMode = Self.makeSettings().chatMode
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        viewModel.streamingState = .streaming(assistantID: assistant.id)
        viewModel.runStream(
            chatMessages: [],
            promptContext: nil,
            resolved: Self.makeResolved(transport),
            assistantID: assistant.id,
            settings: Self.makeSettings(),
            registry: ChatToolRegistry()
        )
        await viewModel.streamingTask?.value

        #expect(assistant.plainText == "kept one kept two")
    }

    @Test("Text stays ahead of reasoning that arrives after it")
    func textAndReasoningKeepArrivalOrder() async {
        let viewModel = AIChatViewModel()
        viewModel.streamFlushClock = NeverTickingClock()

        let transport = UnfoldingTransport(
            events: [
                .textDelta("before "),
                .reasoningDelta(id: "r1", text: "thinking"),
                .reasoningEnd(id: "r1", opaque: nil)
            ]
        ) { _ in }

        let assistant = await runStream(viewModel: viewModel, transport: transport)

        let kinds = assistant.blocks.map { block -> String in
            switch block.kind {
            case .text: return "text"
            case .reasoning: return "reasoning"
            default: return "other"
            }
        }
        #expect(kinds == ["text", "reasoning"])
        #expect(assistant.plainText == "before ")
    }
}
