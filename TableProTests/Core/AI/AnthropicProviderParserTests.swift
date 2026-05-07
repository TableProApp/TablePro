//
//  AnthropicProviderParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AnthropicProvider stream parser")
struct AnthropicProviderParserTests {
    private func parse(_ json: [String: Any], state: inout AnthropicStreamState) throws -> [ChatStreamEvent] {
        try AnthropicProvider.parseChunk(json, state: &state)
    }

    @Test("text_delta yields textDelta")
    func textDelta() throws {
        var state = AnthropicStreamState()
        let events = try parse([
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": "hello"]
        ], state: &state)
        guard case .textDelta(let text) = events.first else {
            Issue.record("expected textDelta; got \(events)")
            return
        }
        #expect(text == "hello")
    }

    @Test("content_block_start with tool_use yields toolUseStart and remembers index→id")
    func toolUseStart() throws {
        var state = AnthropicStreamState()
        let events = try parse([
            "type": "content_block_start",
            "index": 1,
            "content_block": [
                "type": "tool_use",
                "id": "toolu_abc",
                "name": "list_tables"
            ]
        ], state: &state)
        #expect(events.count == 1)
        if case .toolUseStart(let id, let name) = events.first {
            #expect(id == "toolu_abc")
            #expect(name == "list_tables")
        } else {
            Issue.record("expected toolUseStart; got \(events)")
        }
        #expect(state.toolUseIdsByIndex[1] == "toolu_abc")
    }

    @Test("input_json_delta resolves index back to id from state")
    func inputJSONDelta() throws {
        var state = AnthropicStreamState()
        state.toolUseIdsByIndex[1] = "toolu_abc"
        let events = try parse([
            "type": "content_block_delta",
            "index": 1,
            "delta": ["type": "input_json_delta", "partial_json": #"{"foo":"#]
        ], state: &state)
        if case .toolUseDelta(let id, let delta) = events.first {
            #expect(id == "toolu_abc")
            #expect(delta == #"{"foo":"#)
        } else {
            Issue.record("expected toolUseDelta; got \(events)")
        }
    }

    @Test("input_json_delta for unknown index yields nothing")
    func inputJSONDeltaUnknownIndex() throws {
        var state = AnthropicStreamState()
        let events = try parse([
            "type": "content_block_delta",
            "index": 99,
            "delta": ["type": "input_json_delta", "partial_json": "x"]
        ], state: &state)
        #expect(events.isEmpty)
    }

    @Test("content_block_stop yields toolUseEnd and clears the index mapping")
    func toolUseEnd() throws {
        var state = AnthropicStreamState()
        state.toolUseIdsByIndex[1] = "toolu_abc"
        let events = try parse([
            "type": "content_block_stop",
            "index": 1
        ], state: &state)
        if case .toolUseEnd(let id) = events.first {
            #expect(id == "toolu_abc")
        } else {
            Issue.record("expected toolUseEnd; got \(events)")
        }
        #expect(state.toolUseIdsByIndex[1] == nil)
    }

    @Test("Fragmented input_json_delta concatenates correctly via state")
    func fragmentedDelta() throws {
        var state = AnthropicStreamState()
        _ = try parse([
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "tool_use", "id": "tid", "name": "list_tables"]
        ], state: &state)
        let chunk1 = try parse([
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": #"{"con"#]
        ], state: &state)
        let chunk2 = try parse([
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": #"nection_id":"x"}"#]
        ], state: &state)
        let stop = try parse([
            "type": "content_block_stop",
            "index": 0
        ], state: &state)
        let combined = chunk1 + chunk2 + stop
        // textDelta accumulator on the consumer side reassembles fragments.
        let deltas = combined.compactMap { event -> String? in
            if case .toolUseDelta(_, let d) = event { return d }
            return nil
        }
        #expect(deltas.joined() == #"{"connection_id":"x"}"#)
    }

    @Test("message_start tracks input tokens")
    func messageStart() throws {
        var state = AnthropicStreamState()
        _ = try parse([
            "type": "message_start",
            "message": ["usage": ["input_tokens": 42]]
        ], state: &state)
        #expect(state.inputTokens == 42)
    }

    @Test("message_delta tracks output tokens")
    func messageDelta() throws {
        var state = AnthropicStreamState()
        _ = try parse([
            "type": "message_delta",
            "usage": ["output_tokens": 100]
        ], state: &state)
        #expect(state.outputTokens == 100)
    }

    @Test("finalUsageEvent emits .usage when tokens were observed")
    func finalUsage() throws {
        var state = AnthropicStreamState()
        state.inputTokens = 42
        state.outputTokens = 100
        guard case .usage(let usage) = state.finalUsageEvent() else {
            Issue.record("expected usage event")
            return
        }
        #expect(usage.inputTokens == 42)
        #expect(usage.outputTokens == 100)
    }

    @Test("finalUsageEvent returns nil when no tokens observed")
    func noUsageNoEvent() {
        let state = AnthropicStreamState()
        #expect(state.finalUsageEvent() == nil)
    }

    @Test("error event throws streamingFailed")
    func errorEvent() {
        var state = AnthropicStreamState()
        #expect(throws: AIProviderError.self) {
            _ = try AnthropicProvider.parseChunk(
                ["type": "error", "error": ["message": "rate limited"]],
                state: &state
            )
        }
    }

    @Test("decodeStreamLine returns nil for non-data lines and [DONE]")
    func framingDecode() {
        #expect(AnthropicProvider.decodeStreamLine("event: message_stop") == nil)
        #expect(AnthropicProvider.decodeStreamLine("data: [DONE]") == nil)
        #expect(AnthropicProvider.decodeStreamLine("data: {\"type\":\"x\"}") != nil)
    }

    @Test("Unknown event types yield no events and don't throw")
    func unknownEventType() throws {
        var state = AnthropicStreamState()
        let events = try AnthropicProvider.parseChunk(
            ["type": "ping", "extra": "ignored"],
            state: &state
        )
        #expect(events.isEmpty)
        // State should be unchanged.
        #expect(state.toolUseIdsByIndex.isEmpty)
        #expect(state.inputTokens == 0)
    }

    @Test("Chunk with no type field yields no events and doesn't throw")
    func chunkWithoutType() throws {
        var state = AnthropicStreamState()
        let events = try AnthropicProvider.parseChunk(["random": "data"], state: &state)
        #expect(events.isEmpty)
    }
}
