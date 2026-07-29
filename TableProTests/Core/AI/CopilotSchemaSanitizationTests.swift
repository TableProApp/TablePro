//
//  CopilotSchemaSanitizationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Copilot schema sanitization")
struct CopilotSchemaSanitizationTests {
    @Test("Converts type:[X,null] to type:X and drops the field from required")
    func rewritesOptionalScalar() {
        let input = JsonValue.object([
            "type": .string("object"),
            "properties": .object([
                "schema": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "description": .string("optional")
                ])
            ]),
            "required": .array([.string("schema")])
        ])
        let output = ChatToolSpec.sanitizeForCopilot(input)
        guard case .object(let root) = output,
              case .object(let props) = root["properties"],
              case .object(let schemaField) = props["schema"] else {
            Issue.record("expected nested object")
            return
        }
        #expect(schemaField["type"] == .string("string"))
        #expect(root["required"] == .array([]))
    }

    @Test("Preserves non-nullable scalars in required")
    func preservesRequiredFields() {
        let input = JsonValue.object([
            "type": .string("object"),
            "properties": .object([
                "connection_id": .object([
                    "type": .string("string"),
                    "description": .string("UUID")
                ])
            ]),
            "required": .array([.string("connection_id")])
        ])
        let output = ChatToolSpec.sanitizeForCopilot(input)
        guard case .object(let root) = output else { Issue.record("expected object"); return }
        #expect(root["required"] == .array([.string("connection_id")]))
    }

    @Test("Strips null from enum when type was nullable")
    func stripsNullFromEnum() {
        let input = JsonValue.object([
            "type": .string("object"),
            "properties": .object([
                "tier": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "enum": .array([.string("a"), .string("b"), .null])
                ])
            ]),
            "required": .array([.string("tier")])
        ])
        let output = ChatToolSpec.sanitizeForCopilot(input)
        guard case .object(let root) = output,
              case .object(let props) = root["properties"],
              case .object(let tier) = props["tier"] else {
            Issue.record("expected tier object")
            return
        }
        #expect(tier["type"] == .string("string"))
        #expect(tier["enum"] == .array([.string("a"), .string("b")]))
    }

    @Test("Mixed required and optional drop only the nullable")
    func mixedRequiredAndOptional() {
        let input = JsonValue.object([
            "type": .string("object"),
            "properties": .object([
                "connection_id": .object([
                    "type": .string("string")
                ]),
                "schema": .object([
                    "type": .array([.string("string"), .string("null")])
                ])
            ]),
            "required": .array([.string("connection_id"), .string("schema")])
        ])
        let output = ChatToolSpec.sanitizeForCopilot(input)
        guard case .object(let root) = output,
              case .array(let required) = root["required"] else {
            Issue.record("expected required array")
            return
        }
        #expect(required == [.string("connection_id")])
    }

    @Test("Recurses into nested object properties")
    func recursesIntoNested() {
        let input = JsonValue.object([
            "type": .string("object"),
            "properties": .object([
                "filter": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .array([.string("string"), .string("null")])
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ]),
            "required": .array([.string("filter")])
        ])
        let output = ChatToolSpec.sanitizeForCopilot(input)
        guard case .object(let root) = output,
              case .object(let props) = root["properties"],
              case .object(let filter) = props["filter"],
              case .object(let nestedProps) = filter["properties"],
              case .object(let nameField) = nestedProps["name"] else {
            Issue.record("expected nested name field")
            return
        }
        #expect(nameField["type"] == .string("string"))
        #expect(filter["required"] == .array([]))
    }

    @Test("Real ChatToolSchemaBuilder output passes through Copilot validator shape")
    func realBuilderOutputIsValid() throws {
        // Simulates what ListTablesChatTool produces.
        let realSchema = ChatToolSchemaBuilder.object(
            properties: [
                "connection_id": ChatToolSchemaBuilder.connectionId,
                "database": ChatToolSchemaBuilder.string(
                    description: "Database name. Omit to use current.",
                    optional: true
                ),
                "schema": ChatToolSchemaBuilder.schemaName
            ]
        )
        let sanitized = ChatToolSpec.sanitizeForCopilot(realSchema)
        guard case .object(let root) = sanitized,
              case .object(let props) = root["properties"] else {
            Issue.record("expected sanitized object")
            return
        }
        // Every type field at the property level should be a single string.
        for (_, value) in props {
            guard case .object(let field) = value else { continue }
            if case .array = field["type"] {
                Issue.record("type should not be an array after sanitization")
            }
        }
        // Optional fields must be removed from required.
        if case .array(let required) = root["required"] {
            let names = required.compactMap { val -> String? in
                if case .string(let name) = val { return name }
                return nil
            }
            #expect(!names.contains("database"))
            #expect(!names.contains("schema"))
            #expect(names.contains("connection_id"))
        }
    }
}
