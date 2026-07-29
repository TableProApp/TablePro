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

    @Test("toolUse echoes thoughtSignature alongside functionCall when present")
    func toolUseRoundTripsThoughtSignature() throws {
        let toolUse = ToolUseBlock(
            id: "call_1",
            name: "list_tables",
            input: .object([:]),
            providerMetadata: ["thoughtSignature": "sig-abc-123"]
        )
        let turn = ChatTurnWire(role: .assistant, blocks: [.toolUse(toolUse)])
        let encoded = try #require(makeProvider().encodeTurn(turn, priorTurns: []))
        let parts = encoded["parts"] as? [[String: Any]]
        #expect((parts?[0])?["thoughtSignature"] as? String == "sig-abc-123")
        #expect((parts?[0])?["functionCall"] != nil)
    }

    @Test("toolUse without thoughtSignature omits the field")
    func toolUseOmitsSignatureWhenAbsent() throws {
        let toolUse = ToolUseBlock(
            id: "call_1",
            name: "list_tables",
            input: .object([:])
        )
        let turn = ChatTurnWire(role: .assistant, blocks: [.toolUse(toolUse)])
        let encoded = try #require(makeProvider().encodeTurn(turn, priorTurns: []))
        let parts = encoded["parts"] as? [[String: Any]]
        #expect((parts?[0])?["thoughtSignature"] == nil)
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

@Suite("GeminiProvider schema sanitization")
struct GeminiProviderSchemaSanitizationTests {
    @Test("Strips additionalProperties at any depth")
    func stripsAdditionalProperties() {
        let input = JsonValue.object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "nested": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false)
                ])
            ])
        ])
        let output = GeminiProvider.sanitizeSchemaForGemini(input)
        guard case .object(let root) = output else { Issue.record("expected object"); return }
        #expect(root["additionalProperties"] == nil)
        guard case .object(let props) = root["properties"],
              case .object(let nested) = props["nested"] else { Issue.record("expected nested"); return }
        #expect(nested["additionalProperties"] == nil)
    }

    @Test("Converts type:[X,null] to type:X plus nullable:true")
    func rewritesOptionalType() {
        let input = JsonValue.object([
            "type": .array([.string("string"), .string("null")]),
            "description": .string("optional field")
        ])
        let output = GeminiProvider.sanitizeSchemaForGemini(input)
        guard case .object(let fields) = output else { Issue.record("expected object"); return }
        #expect(fields["type"] == .string("string"))
        #expect(fields["nullable"] == .bool(true))
        #expect(fields["description"] == .string("optional field"))
    }

    @Test("Leaves non-nullable type unchanged")
    func preservesNonNullableType() {
        let input = JsonValue.object([
            "type": .string("integer"),
            "description": .string("count")
        ])
        let output = GeminiProvider.sanitizeSchemaForGemini(input)
        guard case .object(let fields) = output else { Issue.record("expected object"); return }
        #expect(fields["type"] == .string("integer"))
        #expect(fields["nullable"] == nil)
    }

    @Test("Recurses into properties and array items")
    func recursesIntoArrayItems() {
        let input = JsonValue.object([
            "type": .string("array"),
            "items": .object([
                "type": .array([.string("string"), .string("null")]),
                "additionalProperties": .bool(false)
            ])
        ])
        let output = GeminiProvider.sanitizeSchemaForGemini(input)
        guard case .object(let root) = output,
              case .object(let items) = root["items"] else { Issue.record("expected items object"); return }
        #expect(items["type"] == .string("string"))
        #expect(items["nullable"] == .bool(true))
        #expect(items["additionalProperties"] == nil)
    }

    @Test("Preserves enum and required fields")
    func preservesEnumAndRequired() {
        let input = JsonValue.object([
            "type": .string("object"),
            "required": .array([.string("id")]),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "enum": .array([.string("a"), .string("b")])
                ])
            ])
        ])
        let output = GeminiProvider.sanitizeSchemaForGemini(input)
        guard case .object(let root) = output else { Issue.record("expected object"); return }
        #expect(root["required"] == .array([.string("id")]))
        guard case .object(let props) = root["properties"],
              case .object(let id) = props["id"] else { Issue.record("expected id"); return }
        #expect(id["enum"] == .array([.string("a"), .string("b")]))
    }
}
