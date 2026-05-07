//
//  AnthropicProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
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
        let turn = ChatTurn(role: .user, blocks: [.text("hello")])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        #expect(encoded?["role"] as? String == "user")
        #expect(encoded?["content"] as? String == "hello")
    }

    @Test("Turn with toolUse becomes a typed-block array, not a flat string")
    func turnWithToolUseIsBlockArray() throws {
        let toolUse = ToolUseBlock(id: "abc", name: "list_tables", input: .object([:]))
        let turn = ChatTurn(role: .assistant, blocks: [.text("checking"), .toolUse(toolUse)])
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
        let turn = ChatTurn(role: .user, blocks: [.toolResult(result)])
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
        let turn = ChatTurn(role: .user, blocks: [.toolResult(result)])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        let blocks = encoded?["content"] as? [[String: Any]]
        #expect((blocks?[0])?["is_error"] as? Bool == true)
    }

    @Test("Empty text turn is dropped")
    func emptyTurnReturnsNil() throws {
        let turn = ChatTurn(role: .user, blocks: [.text("")])
        let encoded = try AnthropicProvider.encodeTurn(turn)
        #expect(encoded == nil)
    }
}
