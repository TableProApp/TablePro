//
//  OpenAIResponsesProviderParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("OpenAIResponsesProvider stream parser")
struct OpenAIResponsesProviderParserTests {
    private func parse(_ json: [String: Any], state: inout ResponsesStreamState) throws -> [ChatStreamEvent] {
        try OpenAIResponsesProvider.parseEvent(json, state: &state)
    }

    @Test("output_text.delta yields textDelta")
    func outputTextDelta() throws {
        var state = ResponsesStreamState()
        let events = try parse([
            "type": "response.output_text.delta",
            "delta": "hello world"
        ], state: &state)
        guard case .textDelta(let text) = events.first else {
            Issue.record("expected textDelta; got \(events)")
            return
        }
        #expect(text == "hello world")
    }

    @Test("output_item.added reasoning yields reasoningStart")
    func reasoningStart() throws {
        var state = ResponsesStreamState()
        let events = try parse([
            "type": "response.output_item.added",
            "item": ["type": "reasoning", "id": "rs_abc"]
        ], state: &state)
        guard case .reasoningStart(let id) = events.first else {
            Issue.record("expected reasoningStart; got \(events)")
            return
        }
        #expect(id == "rs_abc")
        #expect(state.openReasoningItemIDs.contains("rs_abc"))
    }

    @Test("reasoning_summary_text.delta yields reasoningDelta")
    func reasoningSummaryDelta() throws {
        var state = ResponsesStreamState()
        let events = try parse([
            "type": "response.reasoning_summary_text.delta",
            "item_id": "rs_abc",
            "delta": "I should look at"
        ], state: &state)
        guard case .reasoningDelta(let id, let text) = events.first else {
            Issue.record("expected reasoningDelta; got \(events)")
            return
        }
        #expect(id == "rs_abc")
        #expect(text == "I should look at")
    }

    @Test("output_item.done reasoning yields reasoningEnd with encrypted opaque and real itemID")
    func reasoningEndCarriesEncryptedOpaque() throws {
        var state = ResponsesStreamState()
        state.openReasoningItemIDs.insert("rs_abc")
        let events = try parse([
            "type": "response.output_item.done",
            "item": [
                "type": "reasoning",
                "id": "rs_abc",
                "encrypted_content": "BLOB="
            ]
        ], state: &state)
        guard case .reasoningEnd(let id, let opaque) = events.first else {
            Issue.record("expected reasoningEnd; got \(events)")
            return
        }
        #expect(id == "rs_abc")
        #expect(opaque?.kind == .openAIEncrypted)
        #expect(opaque?.itemID == "rs_abc", "Server-issued reasoning id must round-trip via opaque")
        #expect(opaque?.value == "BLOB=")
        #expect(opaque?.blockType == "reasoning")
        #expect(state.openReasoningItemIDs.isEmpty)
    }

    @Test("output_item.added function_call yields toolUseStart")
    func functionCallStart() throws {
        var state = ResponsesStreamState()
        let events = try parse([
            "type": "response.output_item.added",
            "item": [
                "type": "function_call",
                "call_id": "call_xyz",
                "name": "execute_query"
            ]
        ], state: &state)
        guard case .toolUseStart(let id, let name) = events.first else {
            Issue.record("expected toolUseStart; got \(events)")
            return
        }
        #expect(id == "call_xyz")
        #expect(name == "execute_query")
    }

    @Test("function_call_arguments.delta yields toolUseDelta")
    func functionCallArgumentsDelta() throws {
        var state = ResponsesStreamState()
        let events = try parse([
            "type": "response.function_call_arguments.delta",
            "call_id": "call_xyz",
            "delta": #"{"query":"#
        ], state: &state)
        guard case .toolUseDelta(let id, let delta) = events.first else {
            Issue.record("expected toolUseDelta; got \(events)")
            return
        }
        #expect(id == "call_xyz")
        #expect(delta == #"{"query":"#)
    }

    @Test("completed event captures usage tokens")
    func completedCapturesUsage() throws {
        var state = ResponsesStreamState()
        _ = try parse([
            "type": "response.completed",
            "response": [
                "usage": [
                    "input_tokens": 42,
                    "output_tokens": 17
                ]
            ]
        ], state: &state)
        #expect(state.inputTokens == 42)
        #expect(state.outputTokens == 17)
        guard case .usage(let usage) = state.finalUsageEvent() else {
            Issue.record("expected usage event")
            return
        }
        #expect(usage.inputTokens == 42)
        #expect(usage.outputTokens == 17)
    }

    @Test("response.failed throws streamingFailed with error message")
    func responseFailedThrows() throws {
        var state = ResponsesStreamState()
        #expect(throws: AIProviderError.self) {
            _ = try OpenAIResponsesProvider.parseEvent([
                "type": "response.failed",
                "response": ["error": ["message": "rate limit exceeded"]]
            ], state: &state)
        }
    }

    @Test("decodeStreamLine handles data prefix and DONE sentinel")
    func decodeStreamLineFraming() {
        let json = OpenAIResponsesProvider.decodeStreamLine(
            #"data: {"type":"response.created","response":{"id":"r1"}}"#
        )
        #expect(json?["type"] as? String == "response.created")
        #expect(OpenAIResponsesProvider.decodeStreamLine("data: [DONE]") == nil)
        #expect(OpenAIResponsesProvider.decodeStreamLine(": comment line") == nil)
    }
}
