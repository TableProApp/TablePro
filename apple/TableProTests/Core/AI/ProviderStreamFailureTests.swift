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
        #expect(ChatCompletionsStreamWire(ollama: false).decodeLine(line) != nil)
        #expect(ChatCompletionsStreamWire(ollama: false).decodeLine("data:[DONE]") == nil)
        #expect(AnthropicStreamWire().decodeLine(#"data:{"type":"ping"}"#) != nil)
        #expect(AnthropicStreamWire().decodeLine("data:[DONE]") == nil)
        #expect(ResponsesStreamWire().decodeLine(#"data:{"type":"response.created"}"#) != nil)
        #expect(ResponsesStreamWire().decodeLine("data:[DONE]") == nil)
        #expect(GeminiStreamWire().decodeLine(#"data:{"candidates":[]}"#) != nil)
    }

    @Test("An error chunk in a chat completions stream fails the stream with its message")
    func errorChunkThrows() {
        var state = OpenAIStreamState()
        let error = #expect(throws: AIProviderError.self) {
            _ = try ChatCompletionsStreamWire(ollama: false).events(
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
        let events = try ChatCompletionsStreamWire(ollama: false).events(
            from: ["error": NSNull(), "choices": [["delta": ["content": "hi"]]]],
            state: &state
        )
        #expect(events.count == 1)
    }

    @Test("A stream that ends having sent nothing is a failure")
    func emptyStreamThrows() {
        let error = #expect(throws: AIProviderError.self) {
            _ = try ChatCompletionsStreamWire(ollama: false).finalEvents(OpenAIStreamState())
        }
        #expect(streamingFailureMessage(error) != nil)
    }

    @Test("A stream that sent text ends normally")
    func textStreamEnds() throws {
        var state = OpenAIStreamState()
        _ = try ChatCompletionsStreamWire(ollama: false).events(
            from: ["choices": [["delta": ["content": "hi"]]]],
            state: &state
        )
        _ = try ChatCompletionsStreamWire(ollama: false).finalEvents(state)
    }

    @Test("A stream with only a finish reason ends normally")
    func finishReasonOnlyEnds() throws {
        var state = OpenAIStreamState()
        _ = try ChatCompletionsStreamWire(ollama: false).events(
            from: ["choices": [["delta": [String: Any](), "finish_reason": "stop"]]],
            state: &state
        )
        _ = try ChatCompletionsStreamWire(ollama: false).finalEvents(state)
    }

    @Test("An Ollama stream that only reports done ends normally")
    func ollamaDoneEnds() throws {
        var state = OpenAIStreamState()
        _ = try ChatCompletionsStreamWire(ollama: false).events(from: ["done": true], state: &state)
        _ = try ChatCompletionsStreamWire(ollama: false).finalEvents(state)
    }

    @Test("Claude, Responses and Gemini streams that end having sent nothing are failures too")
    func emptyStreamThrowsOnEveryWire() {
        let claude = #expect(throws: AIProviderError.self) {
            _ = try AnthropicStreamWire().finalEvents(AnthropicStreamState())
        }
        let responses = #expect(throws: AIProviderError.self) {
            _ = try ResponsesStreamWire().finalEvents(ResponsesStreamState())
        }
        let gemini = #expect(throws: AIProviderError.self) {
            _ = try GeminiStreamWire().finalEvents(GeminiStreamState())
        }
        #expect(streamingFailureMessage(claude) != nil)
        #expect(streamingFailureMessage(responses) != nil)
        #expect(streamingFailureMessage(gemini) != nil)
    }

    @Test("A stream that only says the reply is over ends normally on every wire")
    func endFrameAloneEnds() throws {
        var claude = AnthropicStreamState()
        _ = try AnthropicStreamWire().events(from: ["type": "message_stop"], state: &claude)
        _ = try AnthropicStreamWire().finalEvents(claude)

        var claudeDelta = AnthropicStreamState()
        _ = try AnthropicStreamWire().events(
            from: ["type": "message_delta", "delta": ["stop_reason": "end_turn"]],
            state: &claudeDelta
        )
        _ = try AnthropicStreamWire().finalEvents(claudeDelta)

        var responses = ResponsesStreamState()
        _ = try ResponsesStreamWire().events(
            from: ["type": "response.completed", "response": ["status": "completed"]],
            state: &responses
        )
        _ = try ResponsesStreamWire().finalEvents(responses)

        var gemini = GeminiStreamState()
        _ = try GeminiStreamWire().events(from: ["candidates": [["finishReason": "STOP"]]], state: &gemini)
        _ = try GeminiStreamWire().finalEvents(gemini)
    }

    @Test("A Gemini prompt blocked with no candidates ends normally and keeps its usage")
    func geminiBlockedPromptEnds() throws {
        var state = GeminiStreamState()
        let events = try GeminiStreamWire().events(
            from: ["promptFeedback": ["blockReason": "SAFETY"], "usageMetadata": ["promptTokenCount": 12]],
            state: &state
        )
        #expect(events.isEmpty)
        let final = try GeminiStreamWire().finalEvents(state)
        guard final.count == 1, case .usage(let usage) = final[0] else {
            Issue.record("expected usage only; got \(final)")
            return
        }
        #expect(usage.inputTokens == 12)
    }

    @Test("A Claude stream whose only frames carry no content and no end is a failure")
    func claudeStartOnlyThrows() throws {
        var state = AnthropicStreamState()
        _ = try AnthropicStreamWire().events(
            from: ["type": "message_start", "message": ["usage": ["input_tokens": 12]]],
            state: &state
        )
        #expect(throws: AIProviderError.self) { _ = try AnthropicStreamWire().finalEvents(state) }
    }

    @Test("A Claude error event with no message still fails the stream, with its type")
    func claudeErrorWithoutMessage() {
        var state = AnthropicStreamState()
        let error = #expect(throws: AIProviderError.self) {
            _ = try AnthropicStreamWire().events(
                from: ["type": "error", "error": ["type": "overloaded_error"]],
                state: &state
            )
        }
        #expect(streamingFailureMessage(error) == "overloaded_error")
    }

    @Test("A Responses error event fails the stream with its message, or its code without one")
    func responsesErrorEvent() {
        var state = ResponsesStreamState()
        let withMessage = #expect(throws: AIProviderError.self) {
            _ = try ResponsesStreamWire().events(
                from: ["type": "error", "code": "server_error", "message": "Try again"],
                state: &state
            )
        }
        #expect(streamingFailureMessage(withMessage) == "Try again")
        let withCode = #expect(throws: AIProviderError.self) {
            _ = try ResponsesStreamWire().events(from: ["type": "error", "code": "server_error"], state: &state)
        }
        #expect(streamingFailureMessage(withCode) == "server_error")
    }

    @Test("The final usage follows the closing events")
    func usageComesLast() throws {
        var state = OpenAIStreamState()
        _ = try ChatCompletionsStreamWire(ollama: false).events(
            from: [
                "choices": [["delta": ["reasoning_content": "hm"]]],
                "usage": ["prompt_tokens": 3, "completion_tokens": 4],
            ],
            state: &state
        )
        let final = try ChatCompletionsStreamWire(ollama: false).finalEvents(state)
        guard final.count == 2, case .reasoningEnd = final[0], case .usage(let usage) = final[1] else {
            Issue.record("expected reasoningEnd then usage; got \(final)")
            return
        }
        #expect(usage.inputTokens == 3)
        #expect(usage.outputTokens == 4)
    }
}

struct ToolCallTrackerTests {
    @Test("A second start for an open call opens nothing, and the call keeps its first id")
    func repeatedStartIsIgnored() {
        var tracker = ToolCallTracker<Int>()
        #expect(tracker.start(0, id: "call_a", name: "list_tables") != nil)
        #expect(tracker.start(0, id: "call_b", name: "list_tables") == nil)
        #expect(tracker.id(for: 0) == "call_a")
    }

    @Test("Ending all calls closes them in the order they started")
    func endAllKeepsStartOrder() {
        var tracker = ToolCallTracker<Int>()
        _ = tracker.start(3, id: "c", name: "x")
        _ = tracker.start(1, id: "a", name: "x")
        _ = tracker.start(2, id: "b", name: "x")
        _ = tracker.end(1)
        let ends = tracker.endAll().compactMap { event -> String? in
            if case .toolUseEnd(let id) = event { return id }
            return nil
        }
        #expect(ends == ["c", "b"])
        #expect(tracker.isEmpty)
        #expect(tracker.end(3) == nil)
    }
}
