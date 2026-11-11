//
//  OutputLimitSignalTests.swift
//  TableProTests
//

import Foundation
import TableProMCP
@testable import TablePro
import Testing

private func limits(_ events: [ChatStreamEvent]) -> [ChatOutputLimit] {
    events.compactMap { event in
        if case .outputLimitReached(let limit) = event { return limit }
        return nil
    }
}

struct OutputLimitSignalTests {
    @Test("Anthropic message_delta stop reasons that cut the reply are reported", arguments: [
        ("max_tokens", [ChatOutputLimit.outputTokens]),
        ("model_context_window_exceeded", [.contextWindow]),
        ("end_turn", []),
        ("tool_use", []),
    ] as [(String, [ChatOutputLimit])])
    func anthropicStopReason(reason: String, expected: [ChatOutputLimit]) throws {
        var state = AnthropicStreamState()
        let events = try AnthropicProvider.parseChunk([
            "type": "message_delta",
            "delta": ["stop_reason": reason],
            "usage": ["output_tokens": 12],
        ], state: &state)
        #expect(limits(events) == expected)
        #expect(state.outputTokens == 12)
    }

    @Test("Chat Completions finish_reason length is reported, stop is not", arguments: [
        ("length", [ChatOutputLimit.outputTokens]),
        ("stop", []),
        ("tool_calls", []),
    ] as [(String, [ChatOutputLimit])])
    func chatCompletionsFinishReason(reason: String, expected: [ChatOutputLimit]) {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "choices": [["delta": [:] as [String: Any], "finish_reason": reason]],
        ], state: &state)
        #expect(limits(result.events) == expected)
    }

    @Test("Ollama's done_reason length is reported")
    func ollamaDoneReason() {
        var state = OpenAIStreamState()
        let result = OpenAICompatibleProvider.parseChunk([
            "message": ["content": ""],
            "done": true,
            "done_reason": "length",
        ], state: &state)
        #expect(limits(result.events) == [.outputTokens])
    }

    @Test("A Responses stream that ends incomplete at max_output_tokens is reported, with its usage")
    func responsesIncomplete() throws {
        var state = ResponsesStreamState()
        let events = try OpenAIResponsesProvider.parseEvent([
            "type": "response.incomplete",
            "response": [
                "status": "incomplete",
                "incomplete_details": ["reason": "max_output_tokens"],
                "usage": ["input_tokens": 30, "output_tokens": 64],
            ],
        ], state: &state)
        #expect(limits(events) == [.outputTokens])
        #expect(state.inputTokens == 30)
        #expect(state.outputTokens == 64)
    }

    @Test("A Responses stream cut by its content filter is not an output limit")
    func responsesContentFilter() throws {
        var state = ResponsesStreamState()
        let events = try OpenAIResponsesProvider.parseEvent([
            "type": "response.incomplete",
            "response": ["incomplete_details": ["reason": "content_filter"]],
        ], state: &state)
        #expect(limits(events).isEmpty)
    }

    @Test("Gemini finishReason MAX_TOKENS is reported, STOP is not", arguments: [
        ("MAX_TOKENS", [ChatOutputLimit.outputTokens]),
        ("STOP", []),
    ] as [(String, [ChatOutputLimit])])
    func geminiFinishReason(reason: String, expected: [ChatOutputLimit]) {
        var state = GeminiStreamState()
        let events = GeminiProvider.parseChunk([
            "candidates": [["content": ["parts": [["text": "partial"]]], "finishReason": reason]],
        ], state: &state, idGenerator: { "id" })
        #expect(limits(events) == expected)
    }

    @Test("Claude Code's passed-through message_delta reports the cut")
    func claudeAgentStopReason() {
        let line = #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}}"#
        #expect(ClaudeAgentProvider.decodeEvent(line) == .outputLimit(.outputTokens))
        let ended = #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}"#
        #expect(ClaudeAgentProvider.decodeEvent(ended) == nil)
    }

    @Test("At the output limit the last call is denied even with no arguments yet, and complete calls before it stand")
    func cutLastCallIsDenied() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1", "call_2"],
            names: ["call_1": "list_tables", "call_2": "execute_query"],
            inputs: ["call_1": #"{"schema":"public"}"#, "call_2": ""],
            outputLimit: .outputTokens
        )
        #expect(blocks.count == 2)
        #expect(blocks[0].approvalState == .approved)
        #expect(blocks[0].input == .object(["schema": .string("public")]))
        #expect(blocks[1].approvalState == .denied(reason: AIChatViewModel.cutToolArgumentsContent))
    }

    @Test("At the output limit cut arguments name the limit in the error the model gets")
    func cutArgumentsNameTheLimit() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "execute_query"],
            inputs: ["call_1": #"{"query":"SELECT * FR"#],
            outputLimit: .outputTokens
        )
        #expect(blocks.first?.approvalState == .denied(reason: AIChatViewModel.cutToolArgumentsContent))
    }

    @Test("At the output limit the last call is denied even when its arguments parse, as Gemini and Ollama hand them over")
    func cutLastCallIsDeniedWithParsedArguments() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "execute_query"],
            inputs: ["call_1": "{}"],
            outputLimit: .outputTokens
        )
        #expect(blocks.first?.approvalState == .denied(reason: AIChatViewModel.cutToolArgumentsContent))
    }

    @Test("At the output limit a malformed call before the last keeps the plain reason")
    func earlierMalformedCallKeepsThePlainReason() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1", "call_2"],
            names: ["call_1": "describe_table", "call_2": "list_tables"],
            inputs: ["call_1": #"{"table":"#, "call_2": "{}"],
            outputLimit: .outputTokens
        )
        #expect(blocks[0].approvalState == .denied(reason: AIChatViewModel.unparsableToolArgumentsContent))
        #expect(blocks[1].approvalState == .denied(reason: AIChatViewModel.cutToolArgumentsContent))
    }

    @Test("Without the limit a call with no arguments still runs with none")
    func noLimitKeepsEmptyArguments() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "list_tables"],
            inputs: ["call_1": ""]
        )
        #expect(blocks.first?.approvalState == .approved)
    }

    @Test("A turn keeps its output limit through the saved conversation, and an unknown value reads as none")
    func outputLimitPersists() throws {
        let wire = ChatTurnWire(role: .assistant, blocks: [.text("cut")], outputLimit: .contextWindow)
        let data = try JSONEncoder().encode(wire)
        #expect(try JSONDecoder().decode(ChatTurnWire.self, from: data).outputLimit == .contextWindow)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["outputLimit"] = "somethingNew"
        let future = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatTurnWire.self, from: future)
        #expect(decoded.outputLimit == nil)
        #expect(decoded.plainText == "cut")
    }
}
