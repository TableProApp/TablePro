//
//  ProviderStreamFailureTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ProviderStreamFailureTests {
    private func streamingFailureMessage(_ error: (any Error)?) -> String? {
        guard case .streamingFailed(let message) = error as? AIProviderError else { return nil }
        return message
    }

    @Test("A data line is read with or without the space after the colon")
    func dataPayloadFraming() {
        #expect(SSEEventStream.dataPayload("data: {\"a\":1}") == "{\"a\":1}")
        #expect(SSEEventStream.dataPayload("data:{\"a\":1}") == "{\"a\":1}")
        #expect(SSEEventStream.dataPayload("data:  x") == " x")
        #expect(SSEEventStream.dataPayload("data:") == "")
        #expect(SSEEventStream.dataPayload("event: message_stop") == nil)
        #expect(SSEEventStream.dataPayload(": keep-alive") == nil)
    }

    @Test("Every SSE provider decodes a data line that has no space")
    func providersDecodeLineWithoutSpace() {
        let line = #"data:{"choices":[]}"#
        #expect(OpenAICompatibleProvider.decodeStreamLine(line, providerType: .openAI) != nil)
        #expect(OpenAICompatibleProvider.decodeStreamLine("data:[DONE]", providerType: .openAI) == nil)
        #expect(AnthropicProvider.decodeStreamLine(#"data:{"type":"ping"}"#) != nil)
        #expect(AnthropicProvider.decodeStreamLine("data:[DONE]") == nil)
        #expect(OpenAIResponsesProvider.decodeStreamLine(#"data:{"type":"response.created"}"#) != nil)
        #expect(OpenAIResponsesProvider.decodeStreamLine("data:[DONE]") == nil)
        #expect(GeminiProvider.decodeStreamLine(#"data:{"candidates":[]}"#) != nil)
    }

    @Test("An error chunk in a chat completions stream fails the stream with its message")
    func errorChunkThrows() {
        var state = OpenAIStreamState()
        let error = #expect(throws: AIProviderError.self) {
            _ = try OpenAICompatibleProvider.streamEvents(
                from: ["error": ["message": "Rate limit reached", "code": 429]],
                state: &state
            )
        }
        #expect(streamingFailureMessage(error) == "Rate limit reached")
    }

    @Test("An error sent as a plain string fails the stream")
    func stringErrorThrows() {
        let error = AIProviderError.streamError(in: ["error": "model not loaded"])
        #expect(streamingFailureMessage(error) == "model not loaded")
    }

    @Test("An error object without a message falls back to its status")
    func errorStatusFallback() {
        let error = AIProviderError.streamError(in: ["error": ["code": 429, "status": "RESOURCE_EXHAUSTED"]])
        #expect(streamingFailureMessage(error) == "RESOURCE_EXHAUSTED")
    }

    @Test("A chunk with no error, or a null one, is not a failure")
    func noErrorIsNotAFailure() throws {
        #expect(AIProviderError.streamError(in: ["choices": [[String: Any]]()]) == nil)
        #expect(AIProviderError.streamError(in: ["error": NSNull()]) == nil)
        var state = OpenAIStreamState()
        let events = try OpenAICompatibleProvider.streamEvents(
            from: ["error": NSNull(), "choices": [["delta": ["content": "hi"]]]],
            state: &state
        )
        #expect(events.count == 1)
    }

    @Test("A stream that ends having sent nothing is a failure")
    func emptyStreamThrows() {
        let error = #expect(throws: AIProviderError.self) {
            _ = try OpenAICompatibleProvider.finalStreamEvents(OpenAIStreamState())
        }
        #expect(streamingFailureMessage(error) != nil)
    }

    @Test("A stream that sent text ends normally")
    func textStreamEnds() throws {
        var state = OpenAIStreamState()
        _ = try OpenAICompatibleProvider.streamEvents(
            from: ["choices": [["delta": ["content": "hi"]]]],
            state: &state
        )
        _ = try OpenAICompatibleProvider.finalStreamEvents(state)
    }

    @Test("A stream with only a finish reason ends normally")
    func finishReasonOnlyEnds() throws {
        var state = OpenAIStreamState()
        _ = try OpenAICompatibleProvider.streamEvents(
            from: ["choices": [["delta": [String: Any](), "finish_reason": "stop"]]],
            state: &state
        )
        _ = try OpenAICompatibleProvider.finalStreamEvents(state)
    }

    @Test("An Ollama stream that only reports done ends normally")
    func ollamaDoneEnds() throws {
        var state = OpenAIStreamState()
        _ = try OpenAICompatibleProvider.streamEvents(from: ["done": true], state: &state)
        _ = try OpenAICompatibleProvider.finalStreamEvents(state)
    }
}
