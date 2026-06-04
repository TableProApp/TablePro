//
//  AIChatInlineSourceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
private func makeAISettings(
    enabled: Bool = true,
    provider: AIProviderConfig? = AIProviderConfig(type: .openAI, model: "test-model")
) -> (AISettings, AIProviderConfig?) {
    AIProviderFactory.invalidateCache()
    let providers = provider.map { [$0] } ?? []
    return (
        AISettings(
            enabled: enabled,
            providers: providers,
            activeProviderID: provider?.id,
            inlineSuggestionsEnabled: true,
            includeSchema: false
        ),
        provider
    )
}

private final class StubChatTransport: ChatTransport {
    private let chunks: [String]

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(.textDelta(chunk))
            }
            continuation.finish()
        }
    }

    func fetchAvailableModels() async throws -> [String] { [] }

    func testConnection() async throws -> Bool { true }
}

@Suite("AIChatInlineSource")
@MainActor
struct AIChatInlineSourceTests {
    @Test("Availability uses injected AI settings")
    func availabilityUsesInjectedSettings() {
        let (enabledSettings, _) = makeAISettings()
        let availableSource = AIChatInlineSource(
            schemaProvider: nil,
            connectionPolicy: .alwaysAllow,
            settingsProvider: { enabledSettings }
        )

        #expect(availableSource.isAvailable == true)

        let (disabledSettings, _) = makeAISettings(enabled: false)
        let unavailableSource = AIChatInlineSource(
            schemaProvider: nil,
            connectionPolicy: .alwaysAllow,
            settingsProvider: { disabledSettings }
        )

        #expect(unavailableSource.isAvailable == false)
    }

    @Test("Connection policy can block inline source")
    func connectionPolicyNeverBlocksSource() {
        let (settings, _) = makeAISettings()
        let source = AIChatInlineSource(
            schemaProvider: nil,
            connectionPolicy: .never,
            settingsProvider: { settings }
        )

        #expect(source.isAvailable == false)
    }

    @Test("Request uses injected provider resolver")
    func requestUsesInjectedProviderResolver() async throws {
        let (settings, provider) = makeAISettings()
        let config = try #require(provider)
        let transport = StubChatTransport(chunks: [
            "\n<think>ignore</think>SELECT",
            " 1  \n"
        ])
        let source = AIChatInlineSource(
            schemaProvider: nil,
            connectionPolicy: .alwaysAllow,
            settingsProvider: { settings },
            providerResolver: { _ in
                AIProviderFactory.ResolvedProvider(
                    provider: transport,
                    model: config.model,
                    config: config
                )
            }
        )

        let suggestion = try await source.requestSuggestion(
            context: SuggestionContext(
                textBefore: "SEL",
                fullText: "SEL",
                cursorOffset: 3,
                cursorLine: 0,
                cursorCharacter: 3
            )
        )

        #expect(suggestion?.text == "SELECT 1")
        #expect(suggestion?.replacementText == "SELECT 1")
    }
}
