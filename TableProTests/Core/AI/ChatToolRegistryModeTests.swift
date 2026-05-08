//
//  ChatToolRegistryModeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatToolRegistry mode gating")
@MainActor
struct ChatToolRegistryModeTests {
    private struct StubTool: ChatTool {
        let name: String
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: "ok")
        }
    }

    private static let readOnlyToolNames: [String] = [
        "list_connections",
        "get_connection_status",
        "list_databases",
        "list_schemas",
        "list_tables",
        "describe_table",
        "get_table_ddl"
    ]

    private static func makeRegistryWithAllTools() -> ChatToolRegistry {
        let registry = ChatToolRegistry()
        for name in readOnlyToolNames {
            registry.register(StubTool(name: name))
        }
        registry.register(StubTool(name: "execute_query"))
        registry.register(StubTool(name: "confirm_destructive_operation"))
        return registry
    }

    @Test("Ask mode exposes only read-only tools")
    func askModeReadOnly() {
        let registry = Self.makeRegistryWithAllTools()
        let names = Set(registry.allSpecs(for: .ask).map(\.name))
        #expect(names == Set(Self.readOnlyToolNames))
        #expect(!names.contains("execute_query"))
        #expect(!names.contains("confirm_destructive_operation"))
    }

    @Test("Edit mode adds execute_query but blocks confirm_destructive_operation")
    func editModeAddsExecuteQuery() {
        let registry = Self.makeRegistryWithAllTools()
        let names = Set(registry.allSpecs(for: .edit).map(\.name))
        let expected = Set(Self.readOnlyToolNames + ["execute_query"])
        #expect(names == expected)
        #expect(names.contains("execute_query"))
        #expect(!names.contains("confirm_destructive_operation"))
    }

    @Test("Agent mode exposes every registered tool including confirm_destructive_operation")
    func agentModeExposesAll() {
        let registry = Self.makeRegistryWithAllTools()
        let names = Set(registry.allSpecs(for: .agent).map(\.name))
        let expected = Set(Self.readOnlyToolNames + ["execute_query", "confirm_destructive_operation"])
        #expect(names == expected)
        #expect(names.contains("confirm_destructive_operation"))
    }

    @Test("isToolAllowed agrees with allSpecs for every mode and tool name")
    func isToolAllowedMatchesSpecs() {
        let registry = Self.makeRegistryWithAllTools()
        for mode in AIChatMode.allCases {
            let allowedFromSpecs = Set(registry.allSpecs(for: mode).map(\.name))
            for tool in registry.allTools {
                let allowed = ChatToolRegistry.isToolAllowed(name: tool.name, in: mode)
                #expect(allowed == allowedFromSpecs.contains(tool.name))
            }
        }
    }

    @Test("tool(named:in:) returns nil for tools blocked by the mode")
    func toolLookupRespectsMode() {
        let registry = Self.makeRegistryWithAllTools()
        #expect(registry.tool(named: "execute_query", in: .ask) == nil)
        #expect(registry.tool(named: "execute_query", in: .edit)?.name == "execute_query")
        #expect(registry.tool(named: "confirm_destructive_operation", in: .edit) == nil)
        #expect(registry.tool(named: "confirm_destructive_operation", in: .agent)?.name == "confirm_destructive_operation")
        #expect(registry.tool(named: "list_tables", in: .ask)?.name == "list_tables")
    }

    @Test("Unknown tool names are not allowed in any mode except agent")
    func unknownToolsBlockedOutsideAgent() {
        #expect(ChatToolRegistry.isToolAllowed(name: "future_tool", in: .ask) == false)
        #expect(ChatToolRegistry.isToolAllowed(name: "future_tool", in: .edit) == false)
        #expect(ChatToolRegistry.isToolAllowed(name: "future_tool", in: .agent) == true)
    }
}
