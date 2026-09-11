//
//  MCPRemoteToolApprovalTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A tool from an outside server waits for a human in every mode, at every Safe Mode level, and with
/// a grant already recorded. "Read-only" is the server's claim about itself, and what leaves the
/// machine on such a call is the schema and rows the assistant hands it.
@Suite("Outside MCP tool approval", .serialized)
struct MCPRemoteToolApprovalTests {
    @MainActor
    private struct Fixture {
        let viewModel: AIChatViewModel
        let registry: ChatToolRegistry
        let remoteToolName: String
        let localBuiltInName: String
        let defaults: UserDefaults
        let suite: String
        let chatDirectory: URL
    }

    @MainActor
    private func makeFixture(
        connection: DatabaseConnection,
        assistantMode: Bool = false
    ) throws -> Fixture {
        let suite = "MCPRemoteToolApprovalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = MCPServerStore(defaults: defaults, keychain: StubKeychain())
        let server = MCPServerConfiguration(
            name: "docs",
            endpoint: URL(string: "https://mcp.example.com") ?? URL(fileURLWithPath: "/"),
            allowedConnectionIds: [connection.id]
        )
        #expect(store.upsert(server, token: "t") == nil)

        let registry = ChatToolRegistry(serverStore: store)
        registry.registerBuiltIn(ListTablesChatTool())
        let adapter = MCPRemoteToolAdapter(
            server: server,
            tool: MCPRemoteTool(name: "search", description: "", inputSchema: .object([:]))
        ) { _, _ in "" }
        #expect(registry.register(adapter))

        let chatDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-approval-\(UUID().uuidString)", isDirectory: true)
        let viewModel = AIChatViewModel(
            services: TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: chatDirectory)),
            connection: connection
        )
        let modeStore = WorkspaceContentModeStore(defaults: defaults)
        modeStore.setMode(assistantMode ? .assistant : .browse, connectionId: connection.id)
        viewModel.contentModeStore = modeStore

        return Fixture(
            viewModel: viewModel,
            registry: registry,
            remoteToolName: adapter.name,
            localBuiltInName: "list_tables",
            defaults: defaults,
            suite: suite,
            chatDirectory: chatDirectory
        )
    }

    @MainActor
    private func cleanUp(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
        try? FileManager.default.removeItem(at: fixture.chatDirectory)
    }

    @Test("A remote tool waits for a human in every chat mode")
    @MainActor
    func remoteToolAlwaysPending() throws {
        let connection = TestFixtures.makeConnection()
        let fixture = try makeFixture(connection: connection)
        defer { cleanUp(fixture) }

        for mode in AIChatMode.allCases {
            fixture.viewModel.chatMode = mode
            let state = fixture.viewModel.computeInitialApprovalState(
                for: fixture.remoteToolName,
                input: .object([:]),
                registry: fixture.registry
            )
            #expect(state == .pending)
        }
    }

    @Test("A built-in read-only tool still runs without a card")
    @MainActor
    func builtInReadOnlyStillApproves() throws {
        let connection = TestFixtures.makeConnection()
        let fixture = try makeFixture(connection: connection)
        defer { cleanUp(fixture) }

        let state = fixture.viewModel.computeInitialApprovalState(
            for: fixture.localBuiltInName,
            input: .object([:]),
            registry: fixture.registry
        )

        #expect(state == .approved)
    }

    @Test("A recorded grant does not switch off a remote tool's card")
    @MainActor
    func grantDoesNotBypassARemoteTool() throws {
        var connection = TestFixtures.makeConnection()
        let fixture = try makeFixture(connection: connection)
        defer { cleanUp(fixture) }
        connection.aiAlwaysAllowedTools = [fixture.remoteToolName]
        fixture.viewModel.connection = connection

        let state = fixture.viewModel.computeInitialApprovalState(
            for: fixture.remoteToolName,
            input: .object([:]),
            registry: fixture.registry
        )

        #expect(state == .pending)
    }

    @Test("A Silent connection does not auto-approve a remote tool")
    @MainActor
    func silentConnectionDoesNotBypassARemoteTool() throws {
        var connection = TestFixtures.makeConnection()
        connection.safeModeLevel = .silent
        let fixture = try makeFixture(connection: connection)
        defer { cleanUp(fixture) }

        let state = fixture.viewModel.computeInitialApprovalState(
            for: fixture.remoteToolName,
            input: .object([:]),
            registry: fixture.registry
        )

        #expect(state == .pending)
    }

    @Test("A read-only connection does not deny a remote tool outright; it still asks")
    @MainActor
    func readOnlyConnectionStillAsks() throws {
        var connection = TestFixtures.makeConnection()
        connection.safeModeLevel = .readOnly
        let fixture = try makeFixture(connection: connection)
        defer { cleanUp(fixture) }

        let state = fixture.viewModel.computeInitialApprovalState(
            for: fixture.remoteToolName,
            input: .object([:]),
            registry: fixture.registry
        )

        /// A remote tool reaches no database, so a read-only database level has nothing to say about
        /// it. The card is the gate, and it is always shown.
        #expect(state == .pending)
    }
}
