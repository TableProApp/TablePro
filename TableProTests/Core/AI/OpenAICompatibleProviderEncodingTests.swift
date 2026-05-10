//
//  OpenAICompatibleProviderEncodingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("OpenAICompatibleProvider wire encoding")
struct OpenAICompatibleProviderEncodingTests {
    private func makeProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            endpoint: "https://api.example.com",
            apiKey: "test",
            providerType: .openAI,
            model: "gpt-4"
        )
    }

    @Test("Tool spec wraps in type:function with parameters key")
    func toolSpecKeyShape() throws {
        let spec = ChatToolSpec(
            name: "list_tables",
            description: "List tables",
            inputSchema: .object(["type": .string("object")])
        )
        let encoded = try makeProvider().encodeTool(spec)
        #expect(encoded["type"] as? String == "function")
        let function = encoded["function"] as? [String: Any]
        #expect(function?["name"] as? String == "list_tables")
        #expect(function?["description"] as? String == "List tables")
        #expect(function?["parameters"] != nil)
    }

    @Test("Plain text turn renders flat content string")
    func plainTextTurn() {
        let turn = ChatTurn(role: .user, blocks: [.text("hello")])
        let encoded = makeProvider().encodeTurn(turn)
        #expect(encoded.count == 1)
        #expect(encoded[0]["role"] as? String == "user")
        #expect(encoded[0]["content"] as? String == "hello")
    }

    @Test("Assistant turn with toolUse emits tool_calls with arguments-as-string")
    func assistantWithToolUse() {
        let toolUse = ToolUseBlock(id: "call_1", name: "list_tables", input: .object([:]))
        let turn = ChatTurn(role: .assistant, blocks: [.text("checking"), .toolUse(toolUse)])
        let messages = makeProvider().encodeTurn(turn)
        #expect(messages.count == 1)
        let message = messages[0]
        #expect(message["role"] as? String == "assistant")
        #expect(message["content"] as? String == "checking")
        let toolCalls = message["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 1)
        #expect((toolCalls?[0])?["id"] as? String == "call_1")
        #expect((toolCalls?[0])?["type"] as? String == "function")
        let function = (toolCalls?[0])?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "list_tables")
        // OpenAI requires arguments be a JSON-encoded STRING, not an object.
        #expect(function?["arguments"] is String)
    }

    @Test("Assistant turn with toolUse but no text emits content: NSNull")
    func assistantWithoutText() {
        let toolUse = ToolUseBlock(id: "call_1", name: "list_tables", input: .object([:]))
        let turn = ChatTurn(role: .assistant, blocks: [.toolUse(toolUse)])
        let messages = makeProvider().encodeTurn(turn)
        #expect(messages[0]["content"] is NSNull)
    }

    @Test("User turn with toolResult emits role:tool with tool_call_id")
    func toolResultBecomesToolMessage() {
        let result = ToolResultBlock(toolUseId: "call_1", content: "rows", isError: false)
        let turn = ChatTurn(role: .user, blocks: [.toolResult(result)])
        let messages = makeProvider().encodeTurn(turn)
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "tool")
        #expect(messages[0]["tool_call_id"] as? String == "call_1")
        #expect(messages[0]["content"] as? String == "rows")
    }

    @Test("Multiple toolResult blocks expand to multiple tool messages")
    func multipleToolResults() {
        let r1 = ToolResultBlock(toolUseId: "call_1", content: "a", isError: false)
        let r2 = ToolResultBlock(toolUseId: "call_2", content: "b", isError: false)
        let turn = ChatTurn(role: .user, blocks: [.toolResult(r1), .toolResult(r2)])
        let messages = makeProvider().encodeTurn(turn)
        #expect(messages.count == 2)
        #expect(messages[0]["tool_call_id"] as? String == "call_1")
        #expect(messages[1]["tool_call_id"] as? String == "call_2")
    }

    @Test("Empty text turn returns no messages")
    func emptyTurnYieldsNothing() {
        let turn = ChatTurn(role: .user, blocks: [.text("")])
        let messages = makeProvider().encodeTurn(turn)
        #expect(messages.isEmpty)
    }
}
