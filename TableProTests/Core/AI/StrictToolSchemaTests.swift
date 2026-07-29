//
//  StrictToolSchemaTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Strict tool schema audit")
struct StrictToolSchemaTests {
    private let tools: [any ChatTool] = [
        ListConnectionsChatTool(),
        ListDatabasesChatTool(),
        ListTablesChatTool(),
        DescribeTableChatTool(),
        GetTableDDLChatTool(),
        GetConnectionStatusChatTool(),
        ExecuteQueryChatTool(),
        ConfirmDestructiveOperationChatTool()
    ]

    @Test("ChatToolSpec.strict defaults to true")
    func strictDefaultsTrue() {
        let spec = ChatToolSpec(
            name: "test",
            description: "test",
            inputSchema: .object([:])
        )
        #expect(spec.strict == true)
    }

    @Test("ChatToolSpec.strict survives Codable round-trip with absent key")
    func strictBackwardCompatible() throws {
        let json = #"{"name":"old","description":"old tool","inputSchema":{"object":{}}}"#
        let decoded = try JSONDecoder().decode(ChatToolSpec.self, from: Data(json.utf8))
        #expect(decoded.strict == true, "Legacy specs without strict key must default to true")
    }

    @Test("ChatToolSchemaBuilder.object emits additionalProperties false")
    func builderEmitsAdditionalPropertiesFalse() throws {
        let schema = ChatToolSchemaBuilder.object(properties: [
            "name": ChatToolSchemaBuilder.string(description: "x")
        ])
        let dict = try (schema.jsonObject() as? [String: Any]) ?? [:]
        #expect(dict["additionalProperties"] as? Bool == false)
    }

    @Test("enumString(optional:true) appends null to the enum array under strict mode")
    func enumStringOptionalIncludesNull() throws {
        let schema = ChatToolSchemaBuilder.enumString(
            ["asc", "desc"],
            description: "sort direction",
            optional: true
        )
        let dict = try (schema.jsonObject() as? [String: Any]) ?? [:]
        let typeValue = dict["type"]
        if let union = typeValue as? [String] {
            #expect(union.contains("string"))
            #expect(union.contains("null"))
        } else {
            Issue.record("expected union type, got \(String(describing: typeValue))")
        }
        let enumValues = dict["enum"] as? [Any] ?? []
        let stringValues = enumValues.compactMap { $0 as? String }
        #expect(stringValues.contains("asc"))
        #expect(stringValues.contains("desc"))
        let hasNull = enumValues.contains(where: { $0 is NSNull })
        #expect(hasNull, "enum array must include null when type union includes null")
    }

    @Test("enumString(optional:false) does not include null in the enum array")
    func enumStringRequiredOmitsNull() throws {
        let schema = ChatToolSchemaBuilder.enumString(
            ["asc", "desc"],
            description: "sort direction"
        )
        let dict = try (schema.jsonObject() as? [String: Any]) ?? [:]
        let enumValues = dict["enum"] as? [Any] ?? []
        let hasNull = enumValues.contains(where: { $0 is NSNull })
        #expect(!hasNull)
    }

    @Test("ChatToolSchemaBuilder.object marks all properties required when not specified")
    func builderAutoIncludesRequired() throws {
        let schema = ChatToolSchemaBuilder.object(properties: [
            "a": ChatToolSchemaBuilder.string(description: "x"),
            "b": ChatToolSchemaBuilder.string(description: "y")
        ])
        let dict = try (schema.jsonObject() as? [String: Any]) ?? [:]
        let required = (dict["required"] as? [String]) ?? []
        #expect(Set(required) == Set(["a", "b"]))
    }

    @Test("ChatToolSchemaBuilder.string with optional emits nullable union")
    func nullableUnionForOptional() throws {
        let schema = ChatToolSchemaBuilder.string(description: "x", optional: true)
        let dict = try (schema.jsonObject() as? [String: Any]) ?? [:]
        let type = dict["type"] as? [String]
        #expect(type == ["string", "null"])
    }

    @Test("All registered tools have closed schemas with no missing required keys")
    func toolsAreStrictCompliant() throws {
        for tool in tools {
            let spec = tool.spec
            #expect(spec.strict == true, "\(tool.name) must default to strict")
            let parameters = try (spec.inputSchema.jsonObject() as? [String: Any]) ?? [:]
            #expect(
                parameters["additionalProperties"] as? Bool == false,
                "\(tool.name) schema must set additionalProperties: false"
            )
            let properties = (parameters["properties"] as? [String: Any]) ?? [:]
            let required = Set((parameters["required"] as? [String]) ?? [])
            let missing = Set(properties.keys).subtracting(required)
            #expect(
                missing.isEmpty,
                "\(tool.name): properties \(missing) are not in required; strict mode rejects this"
            )
        }
    }
}
