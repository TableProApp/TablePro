//
//  AppleIntelligenceSchemaBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing
#if canImport(FoundationModels)
import FoundationModels

@Suite("AppleIntelligenceSchemaBuilder")
struct AppleIntelligenceSchemaBuilderTests {
    @available(macOS 26, *)
    @Test("Builds a schema for an object with required and optional properties")
    func buildsObjectSchema() throws {
        let schema = ChatToolSchemaBuilder.object(
            properties: [
                "connectionId": ChatToolSchemaBuilder.string(description: "UUID"),
                "schema": ChatToolSchemaBuilder.string(description: "Schema name", optional: true)
            ],
            required: ["connectionId"]
        )
        let spec = ChatToolSpec(name: "list_tables", description: "List tables", inputSchema: schema)
        #expect(throws: Never.self) {
            _ = try AppleIntelligenceSchemaBuilder.buildGenerationSchema(from: spec)
        }
    }

    @available(macOS 26, *)
    @Test("Builds a schema for an enum field")
    func buildsEnumSchema() throws {
        let schema = ChatToolSchemaBuilder.object(properties: [
            "mode": ChatToolSchemaBuilder.enumString(["ask", "edit", "agent"], description: "Chat mode")
        ])
        let spec = ChatToolSpec(name: "set_mode", description: "Set the chat mode", inputSchema: schema)
        #expect(throws: Never.self) {
            _ = try AppleIntelligenceSchemaBuilder.buildGenerationSchema(from: spec)
        }
    }

    @available(macOS 26, *)
    @Test("Builds a schema for an array field")
    func buildsArraySchema() throws {
        let schema = ChatToolSchemaBuilder.object(properties: [
            "columns": .object([
                "type": .string("array"),
                "description": .string("Column names"),
                "items": .object(["type": .string("string")])
            ])
        ])
        let spec = ChatToolSpec(name: "select_columns", description: "Select columns", inputSchema: schema)
        #expect(throws: Never.self) {
            _ = try AppleIntelligenceSchemaBuilder.buildGenerationSchema(from: spec)
        }
    }

    @available(macOS 26, *)
    @Test("Decodes a JSON arguments object to JsonValue")
    func decodesArguments() throws {
        let json = "{\"connectionId\":\"abc\",\"limit\":10}"
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(JsonValue.self, from: data)
        #expect(decoded["connectionId"]?.stringValue == "abc")
        #expect(decoded["limit"]?.intValue == 10)
    }
}
#endif
