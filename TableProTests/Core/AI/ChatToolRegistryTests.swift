//
//  ChatToolRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatToolRegistry")
@MainActor
struct ChatToolRegistryTests {
    private struct StubTool: ChatTool {
        let name: String
        let description: String
        let inputSchema: JsonValue
        let mode: ChatToolMode
        let response: String

        init(name: String, description: String = "", mode: ChatToolMode = .readOnly, response: String = "ok") {
            self.name = name
            self.description = description
            self.inputSchema = .object(["type": .string("object"), "properties": .object([:])])
            self.mode = mode
            self.response = response
        }

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: response)
        }
    }

    private static let stubContext = ChatToolContext(
        connectionId: nil,
        bridge: MCPConnectionBridge(),
        authPolicy: MCPAuthPolicy()
    )

    @Test("Registered tool can be looked up by name")
    func lookupByName() {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "alpha"))
        #expect(registry.tool(named: "alpha")?.name == "alpha")
        #expect(registry.tool(named: "missing") == nil)
    }

    @Test("Re-registering a tool with the same name replaces the previous one")
    func reregisterReplaces() async throws {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "alpha", response: "old"))
        registry.register(StubTool(name: "alpha", response: "new"))
        #expect(registry.allTools.count == 1)
        let tool = try #require(registry.tool(named: "alpha"))
        let result = try await tool.execute(input: .object([:]), context: Self.stubContext)
        #expect(result.content == "new")
    }

    @Test("execute returns the configured ChatToolResult")
    func executeReturnsResult() async throws {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "alpha", response: "result"))
        let tool = try #require(registry.tool(named: "alpha"))
        let result = try await tool.execute(input: .object([:]), context: Self.stubContext)
        #expect(result.content == "result")
        #expect(result.isError == false)
    }

    @Test("allTools is sorted alphabetically by name")
    func allToolsSorted() {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "charlie"))
        registry.register(StubTool(name: "alpha"))
        registry.register(StubTool(name: "bravo"))
        #expect(registry.allTools.map(\.name) == ["alpha", "bravo", "charlie"])
    }

    @Test("allSpecs mirrors allTools and exposes wire-format ChatToolSpec")
    func specsMirrorTools() {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "list_tables", description: "List tables"))
        let specs = registry.allSpecs
        #expect(specs.count == 1)
        #expect(specs.first?.name == "list_tables")
        #expect(specs.first?.description == "List tables")
    }

    @Test("unregister removes the entry")
    func unregisterRemoves() {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "alpha"))
        registry.unregister(name: "alpha")
        #expect(registry.tool(named: "alpha") == nil)
    }

    @Test("ChatToolResult is Codable for round-trip with ToolResultBlock")
    func chatToolResultRoundTripsThroughCodable() throws {
        let result = ChatToolResult(content: "hello", isError: true)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ChatToolResult.self, from: data)
        #expect(decoded == result)
    }
}
