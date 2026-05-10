//
//  ChatToolSpecCopilotTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ChatToolSpec.asCopilotToolInformation")
struct ChatToolSpecCopilotTests {
    @Test("schema missing required gets empty required array")
    func addsRequiredWhenMissing() throws {
        let spec = ChatToolSpec(
            name: "list_tables",
            description: "List tables",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["connection_id": .object(["type": .string("string")])])
            ])
        )

        let info = spec.asCopilotToolInformation()
        guard case .object(let dict) = info.inputSchema else {
            Issue.record("inputSchema should remain an object")
            return
        }
        #expect(dict["required"] == .array([]))
    }

    @Test("schema with existing required is preserved")
    func preservesExistingRequired() throws {
        let spec = ChatToolSpec(
            name: "describe_table",
            description: "Describe table",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["table": .object(["type": .string("string")])]),
                "required": .array([.string("table")])
            ])
        )

        let info = spec.asCopilotToolInformation()
        guard case .object(let dict) = info.inputSchema else {
            Issue.record("inputSchema should remain an object")
            return
        }
        #expect(dict["required"] == .array([.string("table")]))
    }

    @Test("non-object schema is passed through unchanged")
    func nonObjectSchemaUnchanged() throws {
        let spec = ChatToolSpec(
            name: "noop",
            description: "no schema",
            inputSchema: .null
        )
        let info = spec.asCopilotToolInformation()
        #expect(info.inputSchema == .null)
    }

    @Test("name and description carry through")
    func passesNameAndDescription() throws {
        let spec = ChatToolSpec(
            name: "execute_query",
            description: "Execute a SQL query",
            inputSchema: .object(["type": .string("object")])
        )
        let info = spec.asCopilotToolInformation()
        #expect(info.name == "execute_query")
        #expect(info.description == "Execute a SQL query")
    }
}
