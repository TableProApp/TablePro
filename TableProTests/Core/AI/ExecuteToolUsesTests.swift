//
//  ExecuteToolUsesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIChatViewModel.executeToolUses")
@MainActor
struct ExecuteToolUsesTests {
    /// Stub tool that returns a fixed response when invoked. Tracks invocation
    /// count and the input it received so tests can assert dispatch behaviour.
    private final class StubTool: ChatTool {
        let name: String
        let description: String
        let inputSchema: JsonValue
        let response: String
        let isError: Bool
        private(set) var invocations: [JsonValue] = []

        init(name: String, response: String = "ok", isError: Bool = false) {
            self.name = name
            self.description = ""
            self.inputSchema = .object(["type": .string("object")])
            self.response = response
            self.isError = isError
        }

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            invocations.append(input)
            return ChatToolResult(content: response, isError: isError)
        }
    }

    /// Tool that always throws when called. Used to verify the error path
    /// returns a ToolResultBlock with isError: true rather than crashing.
    private struct ThrowingTool: ChatTool {
        let name: String
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])
        struct Boom: Error {}
        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            throw Boom()
        }
    }

    private func makeContext() -> ChatToolContext {
        ChatToolContext(
            connectionId: nil,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
    }

    @Test("Resolves tool by name and returns its content as a ToolResultBlock")
    func dispatchesToRegisteredTool() async {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "alpha", response: "hello"))
        let blocks = [ToolUseBlock(id: "u1", name: "alpha", input: .object([:]))]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(results.count == 1)
        #expect(results[0].toolUseId == "u1")
        #expect(results[0].content == "hello")
        #expect(results[0].isError == false)
    }

    @Test("Tools execute in parallel; results come back in input order")
    func resultsAreInInputOrder() async {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "alpha", response: "A"))
        registry.register(StubTool(name: "bravo", response: "B"))
        registry.register(StubTool(name: "charlie", response: "C"))
        let blocks = [
            ToolUseBlock(id: "u1", name: "charlie", input: .object([:])),
            ToolUseBlock(id: "u2", name: "alpha", input: .object([:])),
            ToolUseBlock(id: "u3", name: "bravo", input: .object([:]))
        ]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(results.map(\.toolUseId) == ["u1", "u2", "u3"])
        #expect(results.map(\.content) == ["C", "A", "B"])
    }

    @Test("Unregistered tool name yields isError: true result with explanation")
    func unregisteredToolReturnsError() async {
        let registry = ChatToolRegistry()
        let blocks = [ToolUseBlock(id: "u1", name: "ghost", input: .object([:]))]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(results.count == 1)
        #expect(results[0].isError == true)
        #expect(results[0].content.contains("ghost"))
    }

    @Test("Throwing tool yields isError: true with the error description")
    func throwingToolReturnsError() async {
        let registry = ChatToolRegistry()
        registry.register(ThrowingTool(name: "boom"))
        let blocks = [ToolUseBlock(id: "u1", name: "boom", input: .object([:]))]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(results.count == 1)
        #expect(results[0].isError == true)
        #expect(results[0].content.hasPrefix("Error:"))
    }

    @Test("Tool's own isError flag is propagated to the result block")
    func toolIsErrorPropagates() async {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "warn", response: "permission denied", isError: true))
        let blocks = [ToolUseBlock(id: "u1", name: "warn", input: .object([:]))]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(results[0].isError == true)
        #expect(results[0].content == "permission denied")
    }

    @Test("Mixed registered and unregistered tools each return one result block")
    func mixedToolsAllReturnResults() async {
        let registry = ChatToolRegistry()
        registry.register(StubTool(name: "alpha", response: "A"))
        let blocks = [
            ToolUseBlock(id: "u1", name: "alpha", input: .object([:])),
            ToolUseBlock(id: "u2", name: "missing", input: .object([:]))
        ]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(results.count == 2)
        #expect(results[0].isError == false)
        #expect(results[0].content == "A")
        #expect(results[1].isError == true)
    }

    @Test("Tool receives the input JsonValue from its ToolUseBlock")
    func inputForwarded() async {
        let registry = ChatToolRegistry()
        let stub = StubTool(name: "alpha")
        registry.register(stub)
        let input: JsonValue = .object(["query": .string("SELECT 1")])
        _ = await AIChatViewModel.executeToolUses(
            [ToolUseBlock(id: "u1", name: "alpha", input: input)],
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(stub.invocations.count == 1)
        #expect(stub.invocations.first == input)
    }

    @Test("Empty input array returns empty results")
    func emptyInput() async {
        let registry = ChatToolRegistry()
        let results = await AIChatViewModel.executeToolUses(
            [],
            mode: .agent,
            context: makeContext(),
            registry: registry
        )
        #expect(results.isEmpty)
    }

    @Test("execute_query blocked in Ask mode returns isError result without invoking tool")
    func askModeBlocksExecuteQuery() async {
        let registry = ChatToolRegistry()
        let stub = StubTool(name: "execute_query", response: "should-not-run")
        registry.register(stub)
        let blocks = [ToolUseBlock(id: "u1", name: "execute_query", input: .object([:]))]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .ask,
            context: makeContext(),
            registry: registry
        )
        #expect(results.count == 1)
        #expect(results[0].isError == true)
        #expect(stub.invocations.isEmpty)
    }

    @Test("confirm_destructive_operation blocked in Edit mode returns isError result")
    func editModeBlocksDestructiveConfirm() async {
        let registry = ChatToolRegistry()
        let stub = StubTool(name: "confirm_destructive_operation", response: "should-not-run")
        registry.register(stub)
        let blocks = [ToolUseBlock(id: "u1", name: "confirm_destructive_operation", input: .object([:]))]
        let results = await AIChatViewModel.executeToolUses(
            blocks,
            mode: .edit,
            context: makeContext(),
            registry: registry
        )
        #expect(results.count == 1)
        #expect(results[0].isError == true)
        #expect(stub.invocations.isEmpty)
    }
}
