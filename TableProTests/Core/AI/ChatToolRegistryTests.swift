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
        let inputSchema: JSONValue
        let response: String

        init(name: String, description: String = "", response: String = "ok") {
            self.name = name
            self.description = description
            self.inputSchema = .object(["type": .string("object"), "properties": .object([:])])
            self.response = response
        }

        func execute(input: JSONValue) async throws -> ChatToolResult {
            ChatToolResult(content: response)
        }
    }

    private func makeRegistry() -> ChatToolRegistry {
        let registry = ChatToolRegistry.shared
        for spec in registry.allSpecs {
            registry.unregister(name: spec.name)
        }
        return registry
    }

    @Test("Registered tool can be looked up by name")
    func lookupByName() {
        let registry = makeRegistry()
        registry.register(StubTool(name: "alpha"))
        #expect(registry.tool(named: "alpha")?.name == "alpha")
        #expect(registry.tool(named: "missing") == nil)
    }

    @Test("Re-registering a tool with the same name replaces the previous one")
    func reregisterReplaces() async throws {
        let registry = makeRegistry()
        registry.register(StubTool(name: "alpha", response: "old"))
        registry.register(StubTool(name: "alpha", response: "new"))
        #expect(registry.allTools.count == 1)
        let result = try await runStub(registry.tool(named: "alpha"))
        #expect(result?.content == "new")
    }

    @Test("allTools is sorted alphabetically by name")
    func allToolsSorted() {
        let registry = makeRegistry()
        registry.register(StubTool(name: "charlie"))
        registry.register(StubTool(name: "alpha"))
        registry.register(StubTool(name: "bravo"))
        #expect(registry.allTools.map(\.name) == ["alpha", "bravo", "charlie"])
    }

    @Test("allSpecs mirrors allTools and exposes wire-format ChatToolSpec")
    func specsMirrorTools() {
        let registry = makeRegistry()
        registry.register(StubTool(name: "list_tables", description: "List tables"))
        let specs = registry.allSpecs
        #expect(specs.count == 1)
        #expect(specs.first?.name == "list_tables")
        #expect(specs.first?.description == "List tables")
    }

    @Test("unregister removes the entry")
    func unregisterRemoves() {
        let registry = makeRegistry()
        registry.register(StubTool(name: "alpha"))
        registry.unregister(name: "alpha")
        #expect(registry.tool(named: "alpha") == nil)
    }

    private func runStub(_ tool: (any ChatTool)?) async throws -> ChatToolResult? {
        guard let tool else { return nil }
        return try await tool.execute(input: .object([:]))
    }
}
