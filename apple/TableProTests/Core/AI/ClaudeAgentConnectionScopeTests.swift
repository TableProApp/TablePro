//
//  ClaudeAgentConnectionScopeTests.swift
//  TableProTests
//

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
    func noConnectionMeansNoToken() async {
        #expect(ClaudeAgentMCPBridge.connectionAccess(for: nil) == nil)
        #expect(await ClaudeAgentMCPBridge().makeGrant(connectionId: nil) == nil)
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
