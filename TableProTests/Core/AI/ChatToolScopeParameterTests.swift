//
//  ChatToolScopeParameterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Chat tool scope parameters")
struct ChatToolScopeParameterTests {
    private static func nullableTypes(_ schema: JsonValue?, property: String) -> [String] {
        let type = schema?["properties"]?[property]?["type"]
        return type?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    @Test("Schema reads take an optional database so the chat can reach a non-browse database")
    func schemaReadsTakeDatabase() {
        let tools: [any ChatTool] = [
            ListTablesChatTool(),
            ListSchemasChatTool(),
            DescribeTableChatTool(),
            GetTableDDLChatTool(),
            ExecuteQueryChatTool()
        ]

        for tool in tools {
            let types = Self.nullableTypes(tool.inputSchema, property: "database")
            #expect(types == ["string", "null"], "\(tool.name) must declare a nullable database parameter")
        }
    }

    @Test("Table reads take an optional schema alongside the database")
    func tableReadsTakeSchema() {
        let tools: [any ChatTool] = [
            ListTablesChatTool(),
            DescribeTableChatTool(),
            GetTableDDLChatTool(),
            ExecuteQueryChatTool()
        ]

        for tool in tools {
            let types = Self.nullableTypes(tool.inputSchema, property: "schema")
            #expect(types == ["string", "null"], "\(tool.name) must declare a nullable schema parameter")
        }
    }
}
