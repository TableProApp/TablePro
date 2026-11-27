//
//  AnthropicProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

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

    private let alwaysReasons = AIReasoningSupport(
        mode: .adaptive, effortLevels: [.low, .medium, .high, .xhigh, .max], defaultEffort: .high, isMandatory: true
    )
    private let turnsOff = AIReasoningSupport(
        mode: .adaptive, effortLevels: [.low, .medium, .high, .xhigh], defaultEffort: .high, canTurnOff: true
    )
    private let noExtraHigh = AIReasoningSupport(mode: .adaptive, effortLevels: [.low, .medium, .high], canTurnOff: true)
    private let budgeted = AIReasoningSupport(mode: .budgeted, effortLevels: [.low, .medium, .high])

    private func body(
        model: String = "claude-opus-5",
        effort: ReasoningEffort?,
        maxTokens: Int = 32_768,
        reasoning: AIReasoningSupport?
    ) throws -> [String: Any] {
        try AnthropicProvider.makeRequestBody(
            turns: [ChatTurnWire(role: .user, blocks: [.text("hi")])],
            options: ChatTransportOptions(model: model),
            effort: effort,
            maxTokens: maxTokens,
            stream: true,
            reasoning: reasoning
        )
    }

    @Test("Effort travels in output_config, never inside thinking (#2031)")
    func effortIsNotNestedInThinking() throws {
        let encoded = try body(effort: .medium, reasoning: turnsOff)

        let thinking = encoded["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "adaptive")
        #expect(thinking?["effort"] == nil, "thinking.adaptive has no effort member; the API rejects it")

        let outputConfig = encoded["output_config"] as? [String: Any]
        #expect(outputConfig?["effort"] as? String == "medium")
    }

    @Test("Adaptive thinking asks for summarized reasoning and never carries budget_tokens")
    func adaptiveThinkingShape() throws {
        let thinking = try body(effort: .high, reasoning: alwaysReasons)["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "adaptive")
        #expect(thinking?["display"] as? String == "summarized")
        #expect(thinking?["budget_tokens"] == nil)
    }

    @Test("Extra High and Max serialize as the API names them, and clamp where the model lacks them")
    func effortWireValues() throws {
        #expect((try body(effort: .xhigh, reasoning: turnsOff)["output_config"] as? [String: Any])?["effort"] as? String == "xhigh")
        #expect((try body(effort: .max, reasoning: alwaysReasons)["output_config"] as? [String: Any])?["effort"] as? String == "max")
        #expect((try body(effort: .xhigh, reasoning: noExtraHigh)["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }

    // Claude 5 thinks at high when no thinking field is sent, so Off has to say so.
    @Test("Off sends thinking disabled where the model takes it, and the lowest level where it always reasons")
    func offIsExplicit() throws {
        let off = try body(effort: .off, reasoning: turnsOff)
        #expect((off["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(off["output_config"] == nil)

        let always = try body(effort: .off, reasoning: alwaysReasons)
        #expect((always["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((always["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test("Manual thinking uses a budget and sends no output_config")
    func budgetedThinking() throws {
        let encoded = try body(effort: .medium, reasoning: budgeted)
        let thinking = encoded["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 8_192)
        #expect(encoded["output_config"] == nil, "effort is rejected on manual-thinking models")
    }

    @Test("A budget that cannot clear the API minimum drops thinking instead of sending an invalid one")
    func tinyMaxTokensDropsThinking() throws {
        let encoded = try body(effort: .medium, maxTokens: 1, reasoning: budgeted)
        #expect(encoded["thinking"] == nil)
        #expect(encoded["max_tokens"] as? Int == 1)
    }

    @Test("The budget always stays under max_tokens and at or over the API minimum")
    func budgetStaysBelowMaxTokens() throws {
        let encoded = try body(effort: .high, maxTokens: 2_000, reasoning: budgeted)
        let budget = try #require((encoded["thinking"] as? [String: Any])?["budget_tokens"] as? Int)
        #expect(budget < 2_000)
        #expect(budget >= 1_024)
    }

    @Test("No reasoning parameters are sent with no effort, or for a model nothing describes")
    func noReasoningKeys() throws {
        let unset = try body(effort: nil, reasoning: turnsOff)
        #expect(unset["thinking"] == nil)
        #expect(unset["output_config"] == nil)
        let unknown = try body(model: "claude-opus-9", effort: .high, reasoning: nil)
        #expect(unknown["thinking"] == nil)
        #expect(unknown["output_config"] == nil)
    }

    // A user's 2,000 lost to the effort's 32,768, and a provider with no effort got 4,096 that adaptive thinking ate.
    @Test("max_tokens takes the user's limit first, then the effort's, then 64,000, never above the model's")
    func maxTokensOrder() {
        #expect(AnthropicProvider.maxTokens(requested: 2_000, effort: .high, modelLimit: 128_000) == 2_000)
        #expect(AnthropicProvider.maxTokens(requested: nil, effort: .high, modelLimit: 128_000) == 32_768)
        #expect(AnthropicProvider.maxTokens(requested: nil, effort: nil, modelLimit: nil) == 64_000)
        #expect(AnthropicProvider.maxTokens(requested: nil, effort: .max, modelLimit: 64_000) == 64_000)
        #expect(AnthropicProvider.maxTokens(requested: nil, effort: nil, modelLimit: 8_192) == 8_192)
    }

    @Test("Request body is serializable as JSON")
    func bodySerializes() throws {
        let encoded = try body(effort: .medium, reasoning: turnsOff)
        #expect(JSONSerialization.isValidJSONObject(encoded))
        _ = try JSONSerialization.data(withJSONObject: encoded)
    }
}
