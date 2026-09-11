//
//  ChatToolScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

extension ChatToolScope {
    static func test(
        mode: AIChatMode,
        sessionId: UUID = UUID(),
        connectionId: UUID? = UUID()
    ) -> ChatToolScope {
        ChatToolScope(sessionId: sessionId, connectionId: connectionId, mode: mode)
    }
}

@Suite("Chat tool scope resolution")
@MainActor
struct ChatToolScopeTests {
    private struct StubTool: ChatTool {
        let name: String
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object"), "properties": .object([:])])
        let mode: ChatToolMode

        init(name: String, mode: ChatToolMode = .readOnly) {
            self.name = name
            self.mode = mode
        }

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: "ok")
        }
    }

    private func populated() -> ChatToolRegistry {
        let registry = ChatToolRegistry()
        registry.registerBuiltIn(StubTool(name: "list_tables", mode: .readOnly))
        registry.registerBuiltIn(StubTool(name: "execute_query", mode: .write))
        registry.registerBuiltIn(StubTool(name: "confirm_destructive_operation", mode: .agentOnly))
        return registry
    }

    @Test("Scoped resolution matches mode resolution for built-in tools in every mode")
    func scopeMatchesModeForBuiltIns() {
        let registry = populated()
        for mode in AIChatMode.allCases {
            let scope = ChatToolScope.test(mode: mode)
            #expect(registry.specs(in: scope).map(\.name) == registry.allSpecs(for: mode).map(\.name))
            for tool in registry.allTools {
                #expect(
                    registry.isToolAllowed(name: tool.name, in: scope)
                        == registry.isToolAllowed(name: tool.name, in: mode)
                )
                #expect(
                    registry.tool(named: tool.name, in: scope)?.name
                        == registry.tool(named: tool.name, in: mode)?.name
                )
            }
        }
    }

    @Test("The session and connection do not change which built-in tools resolve")
    func sessionAndConnectionDoNotFilterBuiltIns() {
        let registry = populated()
        let first = ChatToolScope.test(mode: .agent)
        let second = ChatToolScope.test(mode: .agent, sessionId: UUID(), connectionId: UUID())
        let third = ChatToolScope.test(mode: .agent, connectionId: nil)
        #expect(registry.specs(in: first).map(\.name) == registry.specs(in: second).map(\.name))
        #expect(registry.specs(in: first).map(\.name) == registry.specs(in: third).map(\.name))
    }

    @Test("register refuses a name a built-in already holds and leaves the built-in in place")
    func registerRefusesToShadowBuiltIn() throws {
        let registry = populated()
        let shadow = StubTool(name: "execute_query", mode: .readOnly)

        #expect(registry.register(shadow) == false)

        let resolved = try #require(registry.tool(named: "execute_query"))
        #expect(resolved.mode == .write)
    }

    @Test("register accepts a name no built-in holds")
    func registerAcceptsFreeName() {
        let registry = populated()
        #expect(registry.register(StubTool(name: "remote_search")) == true)
        #expect(registry.tool(named: "remote_search")?.name == "remote_search")
    }

    @Test("unregister cannot remove a built-in")
    func unregisterRefusesBuiltIn() {
        let registry = populated()
        registry.unregister(name: "execute_query")
        #expect(registry.tool(named: "execute_query") != nil)
    }

    @Test("unregister removes a tool that is not a built-in")
    func unregisterRemovesNonBuiltIn() {
        let registry = populated()
        registry.register(StubTool(name: "remote_search"))
        registry.unregister(name: "remote_search")
        #expect(registry.tool(named: "remote_search") == nil)
    }
}
