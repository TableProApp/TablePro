//
//  AnthropicProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("AnthropicProvider wire encoding")
struct AnthropicProviderEncodingTests {
    @Test("Tool spec encodes with input_schema (snake_case)")
    func toolSpecKeyCasing() throws {
        let spec = ChatToolSpec(
            name: "list_tables",
            description: "List tables",
            inputSchema: .object(["type": .string("object")])
        )
        let encoded = try AnthropicProvider.encodeToolSpec(spec)
        #expect(encoded["name"] as? String == "list_tables")
        #expect(encoded["description"] as? String == "List tables")
        #expect(encoded["input_schema"] != nil)
    }

    @Test("Plain text turn renders content as a string")
    func plainTextTurn() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("hello")])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        #expect(encoded?["role"] as? String == "user")
        #expect(encoded?["content"] as? String == "hello")
    }

    @Test("Turn with toolUse becomes a typed-block array, not a flat string")
    func turnWithToolUseIsBlockArray() throws {
        let toolUse = ToolUseBlock(id: "abc", name: "list_tables", input: .object([:]))
        let turn = ChatTurnWire(role: .assistant, blocks: [.text("checking"), .toolUse(toolUse)])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        #expect(encoded?["role"] as? String == "assistant")
        let blocks = encoded?["content"] as? [[String: Any]]
        #expect(blocks?.count == 2)
        #expect((blocks?[0])?["type"] as? String == "text")
        #expect((blocks?[1])?["type"] as? String == "tool_use")
        #expect((blocks?[1])?["id"] as? String == "abc")
    }

    @Test("Turn with toolResult uses tool_use_id and omits is_error when false")
    func turnWithSuccessfulToolResult() throws {
        let result = ToolResultBlock(toolUseId: "abc", content: "ok", isError: false)
        let turn = ChatTurnWire(role: .user, blocks: [.toolResult(result)])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        let blocks = encoded?["content"] as? [[String: Any]]
        #expect(blocks?.count == 1)
        #expect((blocks?[0])?["type"] as? String == "tool_result")
        #expect((blocks?[0])?["tool_use_id"] as? String == "abc")
        #expect((blocks?[0])?["content"] as? String == "ok")
        #expect((blocks?[0])?["is_error"] == nil)
    }

    @Test("toolResult with isError emits is_error: true")
    func turnWithErrorToolResult() throws {
        let result = ToolResultBlock(toolUseId: "abc", content: "boom", isError: true)
        let turn = ChatTurnWire(role: .user, blocks: [.toolResult(result)])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        let blocks = encoded?["content"] as? [[String: Any]]
        #expect((blocks?[0])?["is_error"] as? Bool == true)
    }

    @Test("Empty text turn is dropped")
    func emptyTurnReturnsNil() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("")])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        #expect(encoded == nil)
    }

    private func body(
        model: String,
        effort: ReasoningEffort?,
        maxTokens: Int = 32_768
    ) throws -> [String: Any] {
        try AnthropicProvider.makeRequestBody(
            turns: [ChatTurnWire(role: .user, blocks: [.text("hi")])],
            options: ChatTransportOptions(model: model),
            effort: effort,
            maxTokens: maxTokens,
            stream: true
        )
    }

    @Test("Effort travels in output_config, never inside thinking (#2031)")
    func effortIsNotNestedInThinking() throws {
        let encoded = try body(model: "claude-opus-4-7", effort: .medium)

        let thinking = encoded["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "adaptive")
        #expect(thinking?["effort"] == nil, "thinking.adaptive has no effort member; the API rejects it")

        let outputConfig = encoded["output_config"] as? [String: Any]
        #expect(outputConfig?["effort"] as? String == "medium")
    }

    @Test("Adaptive thinking asks for summarized reasoning so the Reasoning block is not empty")
    func adaptiveThinkingRequestsSummarizedDisplay() throws {
        let thinking = try body(model: "claude-opus-5", effort: .high)["thinking"] as? [String: Any]
        #expect(thinking?["display"] as? String == "summarized")
    }

    @Test("Adaptive models never carry budget_tokens, which newer models reject")
    func adaptiveModelsOmitBudgetTokens() throws {
        for model in ["claude-opus-4-7", "claude-opus-5", "claude-sonnet-5", "claude-sonnet-4-6"] {
            let thinking = try body(model: model, effort: .high)["thinking"] as? [String: Any]
            #expect(thinking?["type"] as? String == "adaptive", "\(model) must use adaptive thinking")
            #expect(thinking?["budget_tokens"] == nil, "\(model) must not send budget_tokens")
        }
    }

    @Test("Extra High serializes as xhigh, and clamps to high where the model lacks it")
    func extraHighEffortWireValue() throws {
        let modern = try body(model: "claude-opus-5", effort: .xhigh)["output_config"] as? [String: Any]
        #expect(modern?["effort"] as? String == "xhigh")

        let fourSix = try body(model: "claude-sonnet-4-6", effort: .xhigh)["output_config"] as? [String: Any]
        #expect(fourSix?["effort"] as? String == "high", "Sonnet 4.6 has no xhigh level")
    }

    @Test("Pre-4.6 models use a thinking budget and send no output_config")
    func legacyModelsUseBudgetedThinking() throws {
        let encoded = try body(model: "claude-haiku-4-5", effort: .medium)

        let thinking = encoded["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 8_192)
        #expect(encoded["output_config"] == nil, "effort is rejected on Haiku 4.5")
    }

    @Test("A budget that cannot clear the API minimum drops thinking instead of sending an invalid one")
    func tinyMaxTokensDropsThinking() throws {
        let encoded = try body(model: "claude-haiku-4-5", effort: .medium, maxTokens: 1)
        #expect(encoded["thinking"] == nil)
        #expect(encoded["max_tokens"] as? Int == 1)
    }

    @Test("Minimal effort asks for the smallest budget, not the largest")
    func minimalEffortDoesNotConsumeTheWholeCeiling() throws {
        let minimal = try #require(
            (try body(model: "claude-haiku-4-5", effort: .minimal, maxTokens: 4_096)["thinking"]
                as? [String: Any])?["budget_tokens"] as? Int
        )
        let low = try #require(
            (try body(model: "claude-haiku-4-5", effort: .low, maxTokens: 4_096)["thinking"]
                as? [String: Any])?["budget_tokens"] as? Int
        )
        #expect(minimal <= low, "Minimal must not request more thinking than Low")
        #expect(minimal < 4_096 / 2, "Minimal must leave room for the answer")
    }

    @Test("The budget always stays under max_tokens")
    func budgetStaysBelowMaxTokens() throws {
        let encoded = try body(model: "claude-haiku-4-5", effort: .xhigh, maxTokens: 2_000)
        let budget = try #require((encoded["thinking"] as? [String: Any])?["budget_tokens"] as? Int)
        #expect(budget < 2_000)
        #expect(budget >= AnthropicModelCapabilities.minimumThinkingBudgetTokens)
    }

    @Test("No reasoning parameters are sent when no effort is configured")
    func noEffortMeansNoReasoningKeys() throws {
        let encoded = try body(model: "claude-opus-4-7", effort: nil)
        #expect(encoded["thinking"] == nil)
        #expect(encoded["output_config"] == nil)
    }

    @Test("An unrecognised future model gets adaptive thinking with its effort")
    func unknownModelUsesAdaptive() throws {
        let encoded = try body(model: "claude-opus-9", effort: .high)
        #expect((encoded["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((encoded["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test("Request body is serializable as JSON")
    func bodySerializes() throws {
        let encoded = try body(model: "claude-opus-4-7", effort: .medium)
        #expect(JSONSerialization.isValidJSONObject(encoded))
        _ = try JSONSerialization.data(withJSONObject: encoded)
    }
}
