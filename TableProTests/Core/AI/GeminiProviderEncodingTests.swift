//
//  GeminiProviderEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("GeminiProvider wire encoding")
struct GeminiProviderEncodingTests {
    private func makeProvider() -> GeminiProvider {
        GeminiProvider(
            endpoint: "https://generativelanguage.googleapis.com",
            apiKey: "test"
        )
    }

    @Test("Plain text user turn becomes parts:[{text:...}] with role user")
    func plainTextTurn() throws {
        let turn = ChatTurnWire(role: .user, blocks: [.text("hello")])
        let encoded = try #require(makeProvider().encodeTurn(turn, priorTurns: []))
        #expect(encoded["role"] as? String == "user")
        let parts = encoded["parts"] as? [[String: Any]]
        #expect(parts?.count == 1)
        #expect((parts?[0])?["text"] as? String == "hello")
    }

    @Test("Assistant role maps to model")
    func assistantRoleMapsToModel() throws {
        let turn = ChatTurnWire(role: .assistant, blocks: [.text("hi")])
        let encoded = try #require(makeProvider().encodeTurn(turn, priorTurns: []))
        #expect(encoded["role"] as? String == "model")
    }

    @Test("toolUse becomes functionCall part with args as JSON object")
    func toolUseAsFunctionCall() throws {
        let toolUse = ToolUseBlock(
            id: "call_1",
            name: "list_tables",
            input: .object(["connection_id": .string("abc")])
        )
        let turn = ChatTurnWire(role: .assistant, blocks: [.toolUse(toolUse)])
        let encoded = try #require(makeProvider().encodeTurn(turn, priorTurns: []))
        let parts = encoded["parts"] as? [[String: Any]]
        let functionCall = (parts?[0])?["functionCall"] as? [String: Any]
        #expect(functionCall?["name"] as? String == "list_tables")
        // args MUST be a JSON object (not a string, unlike OpenAI).
        let args = functionCall?["args"] as? [String: Any]
        #expect(args?["connection_id"] as? String == "abc")
    }

    @Test("toolResult resolves the originating tool name from prior turns")
    func toolResultLookupAcrossTurns() throws {
        let toolUse = ToolUseBlock(id: "call_1", name: "list_tables", input: .object([:]))
        let assistantTurn = ChatTurnWire(role: .assistant, blocks: [.toolUse(toolUse)])
        let interveningTurn = ChatTurnWire(role: .user, blocks: [.text("ok")])
        let resultTurn = ChatTurnWire(
            role: .user,
            blocks: [.toolResult(ToolResultBlock(toolUseId: "call_1", content: "rows", isError: false))]
        )
        // resultTurn is at index 2, priorTurns includes both assistantTurn and interveningTurn.
        let encoded = try #require(makeProvider().encodeTurn(
            resultTurn,
            priorTurns: [assistantTurn, interveningTurn]
        ))
        let parts = encoded["parts"] as? [[String: Any]]
        let functionResponse = (parts?[0])?["functionResponse"] as? [String: Any]
        #expect(functionResponse?["name"] as? String == "list_tables")
        let response = functionResponse?["response"] as? [String: Any]
        #expect(response?["content"] as? String == "rows")
    }

    @Test("toolResult with no matching toolUse falls back to toolUseId as name")
    func toolResultFallback() throws {
        let resultTurn = ChatTurnWire(
            role: .user,
            blocks: [.toolResult(ToolResultBlock(toolUseId: "unknown", content: "x", isError: false))]
        )
        let encoded = try #require(makeProvider().encodeTurn(resultTurn, priorTurns: []))
        let parts = encoded["parts"] as? [[String: Any]]
        let functionResponse = (parts?[0])?["functionResponse"] as? [String: Any]
        #expect(functionResponse?["name"] as? String == "unknown")
    }

    @Test("System turns are skipped from encoded contents")
    func systemTurnsSkipped() {
        let system = ChatTurnWire(role: .system, blocks: [.text("ignored")])
        let user = ChatTurnWire(role: .user, blocks: [.text("hello")])
        let contents = makeProvider().encodeContents(turns: [system, user])
        #expect(contents.count == 1)
        #expect(contents[0]["role"] as? String == "user")
    }
}
