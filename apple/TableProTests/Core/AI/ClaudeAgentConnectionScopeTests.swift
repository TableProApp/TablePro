import Foundation
@testable import TablePro
import TableProMCP
import Testing

private actor RecordingToolBridge: ClaudeAgentMCPBridging {
    private(set) var requested: [UUID?] = []

    func makeGrant(connectionId: UUID?) async -> ClaudeAgentToolGrant? {
        requested.append(connectionId)
        return nil
    }

    func release(_ grant: ClaudeAgentToolGrant?) async {}
}

private struct FailingToolBridge: ClaudeAgentMCPBridging {
    func makeGrant(connectionId: UUID?) async throws -> ClaudeAgentToolGrant? {
        throw ClaudeAgentToolGrantError.tokenNotSaved
    }

    func release(_ grant: ClaudeAgentToolGrant?) async {}
}

private struct RefusingCredentialStore: MCPTokenCredentialStoring {
    func read() -> MCPTokenBlob { .found(Data("[]".utf8)) }

    func write(_ data: Data) -> Bool { false }

    func delete() {}
}

struct ClaudeAgentConnectionScopeTests {
    @Test("The token reaches the conversation's connection and no other")
    func tokenIsLimitedToTheConversationConnection() throws {
        let connectionId = UUID()
        let access = try #require(ClaudeAgentMCPBridge.connectionAccess(for: connectionId))

        #expect(access == .limited([connectionId]))
        #expect(access.allows(connectionId))
        #expect(!access.allows(UUID()))
    }

    @Test("A conversation with no connection gets no token")
    func noConnectionMeansNoToken() async throws {
        #expect(ClaudeAgentMCPBridge.connectionAccess(for: nil) == nil)
        #expect(try await ClaudeAgentMCPBridge().makeGrant(connectionId: nil) == nil)
    }

    @Test("A token the Keychain refused stops the grant with a reason instead of dropping the tools")
    func unsavedTokenIsAnError() async throws {
        let store = MCPTokenStore(credentialStore: RefusingCredentialStore())
        let endpoint = try #require(URL(string: "http://127.0.0.1:1/mcp"))
        let bridge = ClaudeAgentMCPBridge(endpoint: { endpoint }, tokenStore: { store })

        await #expect(throws: ClaudeAgentToolGrantError.tokenNotSaved) {
            _ = try await bridge.makeGrant(connectionId: UUID())
        }
        #expect(await store.list().isEmpty)
        #expect(ClaudeAgentToolGrantError.tokenNotSaved.localizedDescription.contains("Keychain"))
    }

    @Test("The chat gets the grant's failure as the turn's error")
    func grantFailureEndsTheTurn() async throws {
        let provider = ClaudeAgentProvider(
            model: "sonnet",
            cli: ClaudeAgentCLI(executableOverride: "/usr/bin/true"),
            toolBridge: FailingToolBridge()
        )
        let stream = provider.streamChat(
            turns: [ChatTurnWire(role: .user, blocks: [.text("hi")])],
            options: ChatTransportOptions(model: "sonnet", connectionId: UUID())
        )

        await #expect(throws: ClaudeAgentToolGrantError.tokenNotSaved) {
            for try await _ in stream {}
        }
    }

    @Test("Transport options carry no connection unless the caller names one")
    func optionsDefaultToNoConnection() {
        #expect(ChatTransportOptions(model: "sonnet").connectionId == nil)
    }

    @Test("The provider asks for a grant on the connection in its options")
    func providerPassesTheConnectionToTheBridge() async throws {
        let bridge = RecordingToolBridge()
        let provider = ClaudeAgentProvider(
            model: "sonnet",
            cli: ClaudeAgentCLI(executableOverride: "/usr/bin/true"),
            toolBridge: bridge
        )
        let connectionId = UUID()

        let stream = provider.streamChat(
            turns: [ChatTurnWire(role: .user, blocks: [.text("hi")])],
            options: ChatTransportOptions(model: "sonnet", connectionId: connectionId)
        )
        for try await _ in stream {}

        #expect(await bridge.requested == [connectionId])
    }
}
