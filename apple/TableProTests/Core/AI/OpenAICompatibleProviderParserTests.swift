//
//  OpenAICompatibleProviderParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OpenAICompatibleProviderParserTests {
    private let wire = ChatCompletionsStreamWire(ollama: false)

    @Test("delta.content yields textDelta")
    func textDelta() {
        var state = OpenAIStreamState()
        let events = wire.parse([
            "choices": [[
                "delta": ["content": "hello"]
            ]]
        ], state: &state)
        guard case .textDelta(let text) = events.first else {
            Issue.record("expected textDelta; got \(events)")
            return
        }
        #expect(text == "hello")
    }

    @Test("First tool_calls chunk emits toolUseStart with id and name")
    func toolUseStart() {
        var state = OpenAIStreamState()
        let events = wire.parse([
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
        #expect(events.count == 1)
        if case .toolUseStart(let id, let name, _) = events.first {
            #expect(id == "call_abc")
            #expect(name == "list_tables")
        } else {
            Issue.record("expected toolUseStart; got \(events)")
        }
        #expect(state.toolCalls.id(for: 0) == "call_abc")
    }

    @Test("Subsequent tool_calls chunks emit toolUseDelta only")
    func toolUseDelta() {
        var state = OpenAIStreamState()
        _ = state.toolCalls.start(0, id: "call_abc", name: "list_tables")
        let events = wire.parse([
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "function": ["arguments": #"{"foo":"#]
                    ]]
                ]
            ]]
        ], state: &state)
        #expect(events.count == 1)
        if case .toolUseDelta(let id, let delta) = events.first {
            #expect(id == "call_abc")
            #expect(delta == #"{"foo":"#)
        } else {
            Issue.record("expected toolUseDelta; got \(events)")
        }
    }

    @Test("finish_reason: tool_calls flushes toolUseEnds for all tracked calls")
    func finishReasonTriggersFlush() {
        var state = OpenAIStreamState()
        _ = state.toolCalls.start(0, id: "call_a", name: "list_tables")
        _ = state.toolCalls.start(1, id: "call_b", name: "describe_table")
        let events = wire.parse([
            "choices": [["finish_reason": "tool_calls"]]
        ], state: &state)
        let endIds = events.compactMap { event -> String? in
            if case .toolUseEnd(let id) = event { return id }
            return nil
        }
        #expect(endIds == ["call_a", "call_b"])
        #expect(state.toolCalls.isEmpty)
    }

    @Test("Ollama message.tool_calls with arguments-as-object encodes to JSON string")
    func ollamaArgumentsAsObject() {
        var state = OpenAIStreamState()
        let events = wire.parse([
            "message": [
                "tool_calls": [[
                    "function": [
                        "name": "list_tables",
                        "arguments": ["connection_id": "abc"]  // object, not string
                    ]
                ]]
            ]
        ], state: &state)
        let deltaPayload = events.compactMap { event -> String? in
            if case .toolUseDelta(_, let s) = event { return s }
            return nil
        }.first
        #expect(deltaPayload?.contains("connection_id") == true)
        #expect(deltaPayload?.contains("abc") == true)
    }

    @Test("Ollama message.tool_calls with arguments-as-string passes through verbatim")
    func ollamaArgumentsAsString() {
        var state = OpenAIStreamState()
        let events = wire.parse([
            "message": [
                "tool_calls": [[
                    "function": [
                        "name": "list_tables",
                        "arguments": #"{"connection_id":"abc"}"#
                    ]
                ]]
            ]
        ], state: &state)
        let delta = events.compactMap { event -> String? in
            if case .toolUseDelta(_, let s) = event { return s }
            return nil
        }.first
        #expect(delta == #"{"connection_id":"abc"}"#)
    }

    @Test("Ollama done: true ends the response and flushes pending tool ends")
    func ollamaDoneFlushesAndBreaks() {
        var state = OpenAIStreamState()
        _ = state.toolCalls.start(0, id: "call_a", name: "list_tables")
        let events = wire.parse([
            "done": true,
            "prompt_eval_count": 50,
            "eval_count": 200
        ], state: &state)
        #expect(state.receivedOutput)
        #expect(events.contains(where: { event in
            if case .toolUseEnd(let id) = event { return id == "call_a" }
            return false
        }))
        #expect(state.inputTokens == 50)
        #expect(state.outputTokens == 200)
    }

    @Test("usage object populates state token counters")
    func usageTokens() {
        var state = OpenAIStreamState()
        _ = wire.parse([
            "usage": ["prompt_tokens": 30, "completion_tokens": 90]
        ], state: &state)
        #expect(state.inputTokens == 30)
        #expect(state.outputTokens == 90)
    }

    @Test("message.content path yields textDelta (Ollama non-stream + final-message OpenAI)")
    func messageContentPathYieldsTextDelta() {
        var state = OpenAIStreamState()
        let events = wire.parse([
            "message": ["content": "hi"]
        ], state: &state)
        guard case .textDelta(let text) = events.first else {
            Issue.record("expected textDelta from message.content; got \(events)")
            return
        }
        #expect(text == "hi")
    }

    @Test("delta.reasoning_content on first chunk emits reasoningStart then reasoningDelta")
    func reasoningContentFirstChunk() {
        var state = OpenAIStreamState()
        let events = wire.parse([
            "choices": [[
                "delta": ["reasoning_content": "Let me think..."]
            ]]
        ], state: &state)
        #expect(events.count == 2)
        guard case .reasoningStart(let id) = events[0] else {
            Issue.record("expected reasoningStart; got \(events[0])")
            return
        }
        guard case .reasoningDelta(let deltaID, let text) = events[1] else {
            Issue.record("expected reasoningDelta; got \(events[1])")
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
        let events = wire.parse([
            "choices": [[
                "delta": ["reasoning_content": " more thinking"]
            ]]
        ], state: &state)
        #expect(events.count == 1)
        guard case .reasoningDelta(let id, let text) = events[0] else {
            Issue.record("expected reasoningDelta; got \(events)")
            return
        }
        #expect(id == "reasoning_abc")
        #expect(text == " more thinking")
    }

    @Test("finish_reason: stop flushes open reasoning block as reasoningEnd with nil opaque")
    func finishReasonStopClosesReasoningBlock() {
        var state = OpenAIStreamState()
        state.reasoningBlockID = "reasoning_xyz"
        let events = wire.parse([
            "choices": [["finish_reason": "stop"]]
        ], state: &state)
        #expect(events.count == 1)
        guard case .reasoningEnd(let id, let opaque) = events[0] else {
            Issue.record("expected reasoningEnd; got \(events)")
            return
        }
        #expect(id == "reasoning_xyz")
        #expect(opaque == nil)
        #expect(state.reasoningBlockID == nil)
    }

    @Test("reasoning_content followed by finish_reason in same chunk emits start, delta, end")
    func reasoningContentWithFinishReason() {
        var state = OpenAIStreamState()
        let events = wire.parse([
            "choices": [[
                "delta": ["reasoning_content": "final thought"],
                "finish_reason": "stop"
            ]]
        ], state: &state)
        let kinds = events.map { event -> String in
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
        let events = wire.parse([
            "choices": [[
                "delta": ["content": "hello", "reasoning_content": NSNull()]
            ]]
        ], state: &state)
        #expect(state.reasoningBlockID == nil)
        #expect(events.count == 1)
        guard case .textDelta = events[0] else {
            Issue.record("expected only textDelta; got \(events)")
            return
        }
    }

    @Test("finish_reason: stop does not flush pending tool calls")
    func finishReasonStopLeavesToolCallsIntact() {
        var state = OpenAIStreamState()
        _ = state.toolCalls.start(0, id: "call_a", name: "list_tables")
        let events = wire.parse([
            "choices": [["finish_reason": "stop"]]
        ], state: &state)
        #expect(events.isEmpty)
        #expect(state.toolCalls.id(for: 0) == "call_a")
    }

    @Test("Empty chunk yields no events and doesn't end the response")
    func emptyChunk() {
        var state = OpenAIStreamState()
        let events = wire.parse([:], state: &state)
        #expect(events.isEmpty)
        #expect(!state.receivedOutput)
    }

    @Test("done: true with no pending tool calls ends the response without emitting")
    func doneWithNoPendingTools() {
        var state = OpenAIStreamState()
        let events = wire.parse(["done": true], state: &state)
        #expect(state.receivedOutput)
        #expect(events.isEmpty)
    }

    @Test("The line decoder follows the framing (SSE vs NDJSON)")
    func decodeStreamLineFraming() {
        let openAIParsed = wire.decodeLine(#"data: {"choices":[]}"#)
        #expect(openAIParsed != nil)
        let openAIDone = wire.decodeLine("data: [DONE]")
        #expect(openAIDone == nil)
        let ollama = ChatCompletionsStreamWire(ollama: true)
        let ollamaParsed = ollama.decodeLine(#"{"done":true}"#)
        #expect(ollamaParsed != nil)
        let ollamaEmpty = ollama.decodeLine("")
        #expect(ollamaEmpty == nil)
    }

    /// Recorded from Meta's Chat Completions endpoint for `muse-spark-1.3`: text, then a tool call
    /// whose id and name come first with empty arguments, and usage on the `finish_reason` chunk.
    @Test("A Meta tool-call stream decodes to text, one tool call and its usage")
    func metaToolCallStream() throws {
        let lines = [
            #"data: {"id":"c1","choices":[{"delta":{"content":"I'll look up the weather.","role":"assistant"},"finish_reason":null,"index":0}],"model":"muse-spark-1.3","object":"chat.completion.chunk"}"#,
            #"data: {"id":"c1","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_01a0","type":"function","function":{"name":"lookup_weather","arguments":""}}]},"finish_reason":null,"index":0}],"model":"muse-spark-1.3","object":"chat.completion.chunk"}"#,
            #"data: {"id":"c1","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":null,"index":0}],"model":"muse-spark-1.3","object":"chat.completion.chunk"}"#,
            #"data: {"id":"c1","choices":[{"delta":{},"finish_reason":"tool_calls","index":0}],"model":"muse-spark-1.3","object":"chat.completion.chunk","usage":{"completion_tokens":139,"prompt_tokens":570,"total_tokens":709,"completion_tokens_details":{"reasoning_tokens":70}}}"#,
            "data: [DONE]"
        ]
        var state = OpenAIStreamState()
        var events: [ChatStreamEvent] = []
        for line in lines {
            guard let json = wire.decodeLine(line) else { continue }
            events += try wire.events(from: json, state: &state)
        }
        events += try wire.finalEvents(state)

        guard events.count == 5 else {
            Issue.record("expected 5 events; got \(events)")
            return
        }
        if case .textDelta(let text) = events[0] { #expect(text == "I'll look up the weather.") } else {
            Issue.record("expected textDelta; got \(events[0])")
        }
        if case .toolUseStart(let id, let name, _) = events[1] {
            #expect(id == "call_01a0")
            #expect(name == "lookup_weather")
        } else {
            Issue.record("expected toolUseStart; got \(events[1])")
        }
        if case .toolUseDelta(let id, let delta) = events[2] {
            #expect(id == "call_01a0")
            #expect(delta == #"{"city":"Paris"}"#)
        } else {
            Issue.record("expected toolUseDelta; got \(events[2])")
        }
        if case .toolUseEnd(let id) = events[3] { #expect(id == "call_01a0") } else {
            Issue.record("expected toolUseEnd; got \(events[3])")
        }
        if case .usage(let usage) = events[4] {
            #expect(usage.inputTokens == 570)
            #expect(usage.outputTokens == 139)
        } else {
            Issue.record("expected usage; got \(events[4])")
        }
    }
}
