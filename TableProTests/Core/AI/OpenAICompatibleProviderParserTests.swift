//
//  OpenAICompatibleProviderParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("OpenAICompatibleProvider stream parser")
struct OpenAICompatibleProviderParserTests {
    @Test("delta.content yields textDelta")
    func textDelta() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [[
                "delta": ["content": "hello"]
            ]]
        ], state: &state)
        #expect(result.shouldBreak == false)
        guard case .textDelta(let text) = result.events.first else {
            Issue.record("expected textDelta; got \(result.events)")
            return
        }
        #expect(text == "hello")
    }

    @Test("First tool_calls chunk emits toolUseStart with id and name")
    func toolUseStart() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call_abc",
                        "type": "function",
                        "function": ["name": "list_tables", "arguments": ""]
                    ]]
                ]
            ]]
        ], state: &state)
        #expect(result.events.count == 1)
        if case .toolUseStart(let id, let name) = result.events.first {
            #expect(id == "call_abc")
            #expect(name == "list_tables")
        } else {
            Issue.record("expected toolUseStart; got \(result.events)")
        }
        #expect(state.toolCallIndexToId[0] == "call_abc")
    }

    @Test("Subsequent tool_calls chunks emit toolUseDelta only")
    func toolUseDelta() {
        var state = OpenAIStreamState()
        state.toolCallIndexToId[0] = "call_abc"
        state.toolCallOrder = [0]
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "function": ["arguments": #"{"foo":"#]
                    ]]
                ]
            ]]
        ], state: &state)
        #expect(result.events.count == 1)
        if case .toolUseDelta(let id, let delta) = result.events.first {
            #expect(id == "call_abc")
            #expect(delta == #"{"foo":"#)
        } else {
            Issue.record("expected toolUseDelta; got \(result.events)")
        }
    }

    @Test("finish_reason: tool_calls flushes toolUseEnds for all tracked calls")
    func finishReasonTriggersFlush() {
        var state = OpenAIStreamState()
        state.toolCallIndexToId = [0: "call_a", 1: "call_b"]
        state.toolCallOrder = [0, 1]
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [["finish_reason": "tool_calls"]]
        ], state: &state)
        let endIds = result.events.compactMap { event -> String? in
            if case .toolUseEnd(let id) = event { return id }
            return nil
        }
        #expect(endIds == ["call_a", "call_b"])
        #expect(state.toolCallIndexToId.isEmpty)
        #expect(state.toolCallOrder.isEmpty)
    }

    @Test("Ollama message.tool_calls with arguments-as-object encodes to JSON string")
    func ollamaArgumentsAsObject() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "message": [
                "tool_calls": [[
                    "function": [
                        "name": "list_tables",
                        "arguments": ["connection_id": "abc"]  // object, not string
                    ]
                ]]
            ]
        ], state: &state)
        let deltaPayload = result.events.compactMap { event -> String? in
            if case .toolUseDelta(_, let s) = event { return s }
            return nil
        }.first
        #expect(deltaPayload?.contains("connection_id") == true)
        #expect(deltaPayload?.contains("abc") == true)
    }

    @Test("Ollama message.tool_calls with arguments-as-string passes through verbatim")
    func ollamaArgumentsAsString() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "message": [
                "tool_calls": [[
                    "function": [
                        "name": "list_tables",
                        "arguments": #"{"connection_id":"abc"}"#
                    ]
                ]]
            ]
        ], state: &state)
        let delta = result.events.compactMap { event -> String? in
            if case .toolUseDelta(_, let s) = event { return s }
            return nil
        }.first
        #expect(delta == #"{"connection_id":"abc"}"#)
    }

    @Test("Ollama done: true sets shouldBreak and flushes pending tool ends")
    func ollamaDoneFlushesAndBreaks() {
        var state = OpenAIStreamState()
        state.toolCallIndexToId[0] = "call_a"
        state.toolCallOrder = [0]
        let result = OpenAICompatibleProvider.parseChunk([
            "done": true,
            "prompt_eval_count": 50,
            "eval_count": 200
        ], state: &state)
        #expect(result.shouldBreak == true)
        #expect(result.events.contains(where: { event in
            if case .toolUseEnd(let id) = event { return id == "call_a" }
            return false
        }))
        #expect(state.inputTokens == 50)
        #expect(state.outputTokens == 200)
    }

    @Test("usage object populates state token counters")
    func usageTokens() {
        var state = OpenAIStreamState()
        _ = OpenAICompatibleProvider.parseChunk([
            "usage": ["prompt_tokens": 30, "completion_tokens": 90]
        ], state: &state)
        #expect(state.inputTokens == 30)
        #expect(state.outputTokens == 90)
    }

    @Test("message.content path yields textDelta (Ollama non-stream + final-message OpenAI)")
    func messageContentPathYieldsTextDelta() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "message": ["content": "hi"]
        ], state: &state)
        guard case .textDelta(let text) = result.events.first else {
            Issue.record("expected textDelta from message.content; got \(result.events)")
            return
        }
        #expect(text == "hi")
    }

    @Test("delta.reasoning_content on first chunk emits reasoningStart then reasoningDelta")
    func reasoningContentFirstChunk() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [[
                "delta": ["reasoning_content": "Let me think..."]
            ]]
        ], state: &state)
        #expect(result.events.count == 2)
        guard case .reasoningStart(let id) = result.events[0] else {
            Issue.record("expected reasoningStart; got \(result.events[0])")
            return
        }
        guard case .reasoningDelta(let deltaID, let text) = result.events[1] else {
            Issue.record("expected reasoningDelta; got \(result.events[1])")
            return
        }
        #expect(deltaID == id)
        #expect(text == "Let me think...")
        #expect(state.reasoningBlockID == id)
    }

    @Test("Subsequent delta.reasoning_content chunks emit only reasoningDelta (no duplicate start)")
    func reasoningContentSubsequentChunk() {
        var state = OpenAIStreamState()
        state.reasoningBlockID = "reasoning_abc"
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [[
                "delta": ["reasoning_content": " more thinking"]
            ]]
        ], state: &state)
        #expect(result.events.count == 1)
        guard case .reasoningDelta(let id, let text) = result.events[0] else {
            Issue.record("expected reasoningDelta; got \(result.events)")
            return
        }
        #expect(id == "reasoning_abc")
        #expect(text == " more thinking")
    }

    @Test("finish_reason: stop flushes open reasoning block as reasoningEnd with nil opaque")
    func finishReasonStopClosesReasoningBlock() {
        var state = OpenAIStreamState()
        state.reasoningBlockID = "reasoning_xyz"
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [["finish_reason": "stop"]]
        ], state: &state)
        #expect(result.events.count == 1)
        guard case .reasoningEnd(let id, let opaque) = result.events[0] else {
            Issue.record("expected reasoningEnd; got \(result.events)")
            return
        }
        #expect(id == "reasoning_xyz")
        #expect(opaque == nil)
        #expect(state.reasoningBlockID == nil)
    }

    @Test("reasoning_content followed by finish_reason in same chunk emits start, delta, end")
    func reasoningContentWithFinishReason() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [[
                "delta": ["reasoning_content": "final thought"],
                "finish_reason": "stop"
            ]]
        ], state: &state)
        let kinds = result.events.map { event -> String in
            switch event {
            case .reasoningStart: return "start"
            case .reasoningDelta: return "delta"
            case .reasoningEnd: return "end"
            default: return "other"
            }
        }
        #expect(kinds == ["start", "delta", "end"])
        #expect(state.reasoningBlockID == nil)
    }

    @Test("delta.reasoning_content: null is ignored and does not emit reasoningStart")
    func reasoningContentNullIgnored() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [[
                "delta": ["content": "hello", "reasoning_content": NSNull()]
            ]]
        ], state: &state)
        #expect(state.reasoningBlockID == nil)
        #expect(result.events.count == 1)
        guard case .textDelta = result.events[0] else {
            Issue.record("expected only textDelta; got \(result.events)")
            return
        }
    }

    @Test("finish_reason: stop does not flush pending tool calls")
    func finishReasonStopLeavesToolCallsIntact() {
        var state = OpenAIStreamState()
        state.toolCallIndexToId = [0: "call_a"]
        state.toolCallOrder = [0]
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [["finish_reason": "stop"]]
        ], state: &state)
        #expect(result.events.isEmpty)
        #expect(state.toolCallIndexToId[0] == "call_a")
    }

    @Test("Empty chunk yields no events and doesn't break")
    func emptyChunk() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([:], state: &state)
        #expect(result.events.isEmpty)
        #expect(result.shouldBreak == false)
    }

    @Test("done: true with no pending tool calls breaks without emitting")
    func doneWithNoPendingTools() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk(["done": true], state: &state)
        #expect(result.shouldBreak == true)
        #expect(result.events.isEmpty)
    }

    @Test("decodeStreamLine respects providerType (SSE vs NDJSON)")
    func decodeStreamLineFraming() {
        let openAIParsed = OpenAICompatibleProvider.decodeStreamLine(
            #"data: {"choices":[]}"#,
            providerType: .openAI
        )
        #expect(openAIParsed != nil)
        let openAIDone = OpenAICompatibleProvider.decodeStreamLine("data: [DONE]", providerType: .openAI)
        #expect(openAIDone == nil)
        let ollamaParsed = OpenAICompatibleProvider.decodeStreamLine(
            #"{"done":true}"#,
            providerType: .ollama
        )
        #expect(ollamaParsed != nil)
        let ollamaEmpty = OpenAICompatibleProvider.decodeStreamLine("", providerType: .ollama)
        #expect(ollamaEmpty == nil)
    }
}
