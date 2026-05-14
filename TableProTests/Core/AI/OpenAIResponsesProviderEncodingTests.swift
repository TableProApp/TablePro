//
//  OpenAIResponsesProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("OpenAIResponsesProvider request encoding")
struct OpenAIResponsesProviderEncodingTests {
    @Test("encodeToolSpec emits flat shape with strict at top level")
    func toolSpecShape() throws {
        let spec = ChatToolSpec(
            name: "ping",
            description: "Ping the database",
            inputSchema: ChatToolSchemaBuilder.object(properties: [
                "host": ChatToolSchemaBuilder.string(description: "host name")
            ])
        )
        let encoded = try OpenAIResponsesProvider.encodeToolSpec(spec)
        #expect(encoded["type"] as? String == "function")
        #expect(encoded["name"] as? String == "ping")
        #expect(encoded["description"] as? String == "Ping the database")
        #expect(encoded["strict"] as? Bool == true)
        #expect(encoded["parameters"] != nil)
        #expect(encoded["function"] == nil, "Responses API tool shape must be flat, not nested")
    }

    @Test("user text turn encodes as input_text message")
    func userTextTurn() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("hello")])
        let items = try OpenAIResponsesProvider.encodeTurn(turn)
        #expect(items.count == 1)
        let message = items[0]
        #expect(message["type"] as? String == "message")
        #expect(message["role"] as? String == "user")
        let content = message["content"] as? [[String: Any]] ?? []
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "hello")
    }

    @Test("assistant turn with reasoning + tool_use emits reasoning item before function_call")
    func reasoningRoundTripOrdering() throws {
        let opaque = ReasoningOpaque(
            kind: .openAIEncrypted,
            itemID: "rs_real_abc",
            value: "BLOB=",
            blockType: "reasoning"
        )
        let reasoning = ReasoningBlock(text: "I should call ping", opaque: opaque)
        let toolUse = ToolUseBlock(id: "call_1", name: "ping", input: .object([:]))
        let turn = ChatTurnWire(role: .assistant, blocks: [
            .reasoning(reasoning),
            .toolUse(toolUse)
        ])
        let items = try OpenAIResponsesProvider.encodeTurn(turn)
        #expect(items.count == 2)
        #expect(items[0]["type"] as? String == "reasoning", "Reasoning item must come before its function_call")
        #expect(items[0]["id"] as? String == "rs_real_abc", "Reasoning item id must round-trip from server")
        #expect(items[0]["encrypted_content"] as? String == "BLOB=")
        #expect(items[1]["type"] as? String == "function_call")
        #expect(items[1]["call_id"] as? String == "call_1")
        #expect(items[1]["name"] as? String == "ping")
    }

    @Test("reasoning + text + tool_use flushes text into message item between reasoning and function_call")
    func reasoningTextToolUseOrdering() throws {
        let opaque = ReasoningOpaque(
            kind: .openAIEncrypted,
            itemID: "rs_1",
            value: "ENC=",
            blockType: "reasoning"
        )
        let turn = ChatTurnWire(role: .assistant, blocks: [
            .text("preface text"),
            .reasoning(ReasoningBlock(opaque: opaque)),
            .toolUse(ToolUseBlock(id: "call_1", name: "ping", input: .object([:])))
        ])
        let items = try OpenAIResponsesProvider.encodeTurn(turn)
        #expect(items.count == 3)
        #expect(items[0]["type"] as? String == "message", "Text emitted before reasoning must flush first")
        #expect(items[1]["type"] as? String == "reasoning")
        #expect(items[2]["type"] as? String == "function_call")
    }

    @Test("assistant turn with [toolUse, text] drops trailing text to keep tool-call adjacent to its output")
    func assistantTrailingTextAfterToolUseDropped() throws {
        let toolUse = ToolUseBlock(id: "call_1", name: "ping", input: .object([:]))
        let turn = ChatTurnWire(role: .assistant, blocks: [
            .toolUse(toolUse),
            .text("trailing chatter")
        ])
        let items = try OpenAIResponsesProvider.encodeTurn(turn)
        #expect(items.count == 1, "Trailing text after function_call must not produce a message item")
        #expect(items[0]["type"] as? String == "function_call")
    }

    @Test("assistant reasoning with empty itemID is skipped, not emitted")
    func reasoningWithEmptyItemIDSkipped() throws {
        let badOpaque = ReasoningOpaque(
            kind: .openAIEncrypted,
            itemID: "",
            value: "ENC=",
            blockType: "reasoning"
        )
        let turn = ChatTurnWire(role: .assistant, blocks: [
            .reasoning(ReasoningBlock(opaque: badOpaque)),
            .text("hi")
        ])
        let items = try OpenAIResponsesProvider.encodeTurn(turn)
        #expect(items.count == 1, "Empty itemID reasoning item must be dropped")
        #expect(items[0]["type"] as? String == "message")
    }

    @Test("ChatContentBlockWire(.reasoning) round-trips through Codable preserving every opaque field")
    func reasoningBlockCodableRoundTrip() throws {
        let opaque = ReasoningOpaque(
            kind: .openAIEncrypted,
            itemID: "rs_roundtrip",
            value: "BLOB==",
            blockType: "reasoning"
        )
        let block: ChatContentBlockWire = .reasoning(ReasoningBlock(text: "think", opaque: opaque))
        let encoded = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ChatContentBlockWire.self, from: encoded)
        switch decoded.kind {
        case .reasoning(let restored):
            #expect(restored.text == "think")
            #expect(restored.opaque?.kind == .openAIEncrypted)
            #expect(restored.opaque?.itemID == "rs_roundtrip")
            #expect(restored.opaque?.value == "BLOB==")
            #expect(restored.opaque?.blockType == "reasoning")
        default:
            Issue.record("decoded was not a reasoning block")
        }
    }

    @Test("user turn with tool_result emits function_call_output with matching call_id")
    func toolResultEncoding() throws {
        let result = ToolResultBlock(toolUseId: "call_1", content: "ok")
        let turn = ChatTurnWire(role: .user, blocks: [.toolResult(result)])
        let items = try OpenAIResponsesProvider.encodeTurn(turn)
        #expect(items.count == 1)
        #expect(items[0]["type"] as? String == "function_call_output")
        #expect(items[0]["call_id"] as? String == "call_1")
        #expect(items[0]["output"] as? String == "ok")
    }

    @Test("remote URL image encodes as input_image with sibling detail")
    func remoteImageEncoding() throws {
        guard let url = URL(string: "https://example.com/cat.png") else {
            Issue.record("invalid url fixture")
            return
        }
        let image = ChatImageInput(
            source: .remoteURL(url, mediaType: "image/png"),
            detailHint: .high
        )
        let turn = ChatTurnWire(role: .user, blocks: [.text("look"), .image(image)])
        let items = try OpenAIResponsesProvider.encodeTurn(turn)
        #expect(items.count == 1)
        let content = items[0]["content"] as? [[String: Any]] ?? []
        let imagePart = content.first(where: { ($0["type"] as? String) == "input_image" })
        #expect(imagePart != nil)
        #expect(imagePart?["image_url"] as? String == "https://example.com/cat.png")
        #expect(imagePart?["detail"] as? String == "high")
        #expect((imagePart?["image_url"] as? [String: Any]) == nil, "Responses input_image must use string image_url, not nested object")
    }
}
