//
//  OpenAICompatibleProviderParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
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
