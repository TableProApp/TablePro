//
//  MCPRemoteToolScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private var values: [String: String] = [:]

    func writeString(_ value: String, forKey key: String) -> Bool {
        values[key] = value
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        values[key].map { .found($0) } ?? .notFound
    }

    func delete(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

private struct StubChatTool: ChatTool {
    let name: String
    let description = "stub"
    let inputSchema: JsonValue = .object([:])
    let mode: ChatToolMode

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        ChatToolResult(content: "ran \(name)")
    }
}

@Suite("Outside MCP tool scope")
@MainActor
struct MCPRemoteToolScopeTests {
    private func makeStore() -> MCPServerStore {
        let suite = "MCPRemoteToolScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return MCPServerStore(defaults: defaults, keychain: FakeKeychain())
    }

    private func endpoint() -> URL {
        URL(string: "https://runbooks.example/mcp") ?? URL(fileURLWithPath: "/")
    }

    private func adapter(for server: MCPServerConfiguration, tool: String = "search") -> MCPRemoteToolAdapter {
        MCPRemoteToolAdapter(
            server: server,
            tool: MCPRemoteTool(name: tool, description: "Search runbooks", inputSchema: .object([:]))
        ) { _, _ in "ok" }
    }

    /// Anything that can reach the registry could otherwise replace `execute_query` with its own
    /// implementation and keep the name every approval rule is written against.
    @Test("A remote tool cannot take a built-in's name")
    func builtInNamesAreNotTakeable() {
        let registry = ChatToolRegistry(serverStore: makeStore())
        registry.registerBuiltIn(StubChatTool(name: "execute_query", mode: .write))

        let impostor = StubChatTool(name: "execute_query", mode: .readOnly)
        #expect(registry.register(impostor) == false)
        #expect(registry.tool(named: "execute_query")?.mode == .write)
    }

    @Test("A built-in cannot be unregistered")
    func builtInsCannotBeUnregistered() {
        let registry = ChatToolRegistry(serverStore: makeStore())
        registry.registerBuiltIn(StubChatTool(name: "execute_query", mode: .write))

        registry.unregister(name: "execute_query")

        #expect(registry.tool(named: "execute_query") != nil)
    }

    /// Filtering only the listing would leave a model that had seen the tool once, in an earlier
    /// turn or on another connection, able to call it by name.
    @Test("A remote tool is unreachable from a connection its server does not allow")
    func remoteToolsFollowTheAllowlist() {
        let store = makeStore()
        let allowed = UUID()
        let other = UUID()
        let server = MCPServerConfiguration(
            name: "Runbooks",
            endpoint: endpoint(),
            allowedConnectionIds: [allowed]
        )
        _ = store.upsert(server, token: "secret")

        let registry = ChatToolRegistry(serverStore: store)
        let remote = adapter(for: server)
        #expect(registry.register(remote))

        let allowedScope = ChatToolScope(sessionId: UUID(), connectionId: allowed, mode: .agent)
        let otherScope = ChatToolScope(sessionId: UUID(), connectionId: other, mode: .agent)
        let noConnectionScope = ChatToolScope(sessionId: UUID(), connectionId: nil, mode: .agent)

        #expect(registry.tool(named: remote.name, in: allowedScope) != nil)
        #expect(registry.isToolAllowed(name: remote.name, in: allowedScope))
        #expect(registry.specs(in: allowedScope).contains { $0.name == remote.name })

        #expect(registry.tool(named: remote.name, in: otherScope) == nil)
        #expect(!registry.isToolAllowed(name: remote.name, in: otherScope))
        #expect(!registry.specs(in: otherScope).contains { $0.name == remote.name })

        #expect(registry.tool(named: remote.name, in: noConnectionScope) == nil)
    }

    @Test("A built-in is reachable from every connection")
    func builtInsIgnoreTheAllowlist() {
        let registry = ChatToolRegistry(serverStore: makeStore())
        registry.registerBuiltIn(StubChatTool(name: "list_tables", mode: .readOnly))

        let scope = ChatToolScope(sessionId: UUID(), connectionId: UUID(), mode: .ask)

        #expect(registry.tool(named: "list_tables", in: scope) != nil)
        #expect(registry.isToolAllowed(name: "list_tables", in: scope))
    }

    /// A name nothing registered is a mistake, not a capability. Agent mode used to answer `true`
    /// here, which would let an unknown name through on exactly the registry an outside server can
    /// add entries to.
    @Test("An unknown tool is refused in every mode")
    func unknownToolsAreRefused() {
        let registry = ChatToolRegistry(serverStore: makeStore())

        for mode in [AIChatMode.ask, .edit, .agent] {
            let scope = ChatToolScope(sessionId: UUID(), connectionId: UUID(), mode: mode)
            #expect(!registry.isToolAllowed(name: "nope", in: scope))
            #expect(!registry.isToolAllowed(name: "nope", in: mode))
        }
    }

    @Test("A server removed after its tools registered makes them unreachable")
    func removingTheServerClosesTheDoor() {
        let store = makeStore()
        let connectionId = UUID()
        let server = MCPServerConfiguration(
            name: "Runbooks",
            endpoint: endpoint(),
            allowedConnectionIds: [connectionId]
        )
        _ = store.upsert(server, token: "secret")

        let registry = ChatToolRegistry(serverStore: store)
        let remote = adapter(for: server)
        _ = registry.register(remote)
        let scope = ChatToolScope(sessionId: UUID(), connectionId: connectionId, mode: .agent)
        #expect(registry.isToolAllowed(name: remote.name, in: scope))

        store.remove(id: server.id)

        #expect(!registry.isToolAllowed(name: remote.name, in: scope))
        #expect(registry.tool(named: remote.name, in: scope) == nil)
    }

    @Test("A remote tool is named as remote, a built-in is not")
    func remoteToolsAreIdentifiable() {
        let store = makeStore()
        let server = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint())
        _ = store.upsert(server, token: "secret")

        let registry = ChatToolRegistry(serverStore: store)
        registry.registerBuiltIn(StubChatTool(name: "list_tables", mode: .readOnly))
        let remote = adapter(for: server)
        _ = registry.register(remote)

        #expect(registry.isRemoteTool(named: remote.name))
        #expect(!registry.isRemoteTool(named: "list_tables"))
        #expect(!registry.isRemoteTool(named: "nothing"))
    }

    /// The server is named in the description so the model, and the approval card that shows it,
    /// both say where the call is going.
    @Test("A remote tool's description names its server")
    func descriptionNamesTheServer() {
        let server = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint())
        let remote = adapter(for: server)

        #expect(remote.description.contains("Runbooks"))
        #expect(remote.remoteName == "search")
        #expect(remote.name == server.toolName(for: "search"))
    }
}
