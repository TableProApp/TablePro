//
//  ContentModeTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Agent mode")
@MainActor
struct ContentModeTests {
    /// The one field that makes a mode toggle repaint anything. Without it the phase holds, the
    /// connection holds and the session is the same, so `syncPanes(of:)` compares equal and the
    /// window keeps drawing the mode it had already drawn.
    @Test("A pure mode toggle changes the pane render key")
    func modeChangesTheRenderKey() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let browse = WorkspacePaneRenderKey(
            pane: .content,
            connection: connection,
            sessionRevision: 3,
            contentMode: .browse,
            agentSessionId: nil
        )
        let agent = WorkspacePaneRenderKey(
            pane: .content,
            connection: connection,
            sessionRevision: 3,
            contentMode: .agent,
            agentSessionId: nil
        )
        #expect(browse != agent)
    }

    @Test("Agent mode resolves back to browsing when the AI feature is off")
    func agentModeNeedsTheFeature() {
        #expect(ConnectionWorkspaceContentMode.resolved(.agent, isAIEnabled: false) == .browse)
        #expect(ConnectionWorkspaceContentMode.resolved(.agent, isAIEnabled: true) == .agent)
        #expect(ConnectionWorkspaceContentMode.resolved(.browse, isAIEnabled: false) == .browse)
    }

    @Test("The mode toggles between exactly two states")
    func toggling() {
        #expect(ConnectionWorkspaceContentMode.browse.toggled == .agent)
        #expect(ConnectionWorkspaceContentMode.agent.toggled == .browse)
    }

    /// The result pane belongs to the mode, not to a command, so it must never land in the stored
    /// per-connection surface preference and displace what the user chose for browsing.
    @Test("The result surface is not user-selectable and is never stored")
    func resultSurfaceIsModeOwned() {
        #expect(TrailingPaneSurface.agentResult.isUserSelectable == false)
        #expect(TrailingPaneSurface.inspector.isUserSelectable)
        #expect(TrailingPaneSurface.assistant.isUserSelectable)

        let defaults = UserDefaults(suiteName: "ContentModeTests-\(UUID().uuidString)")
        let connectionId = UUID()
        let state = TrailingPaneState(connectionId: connectionId, defaults: defaults ?? .standard)
        state.surface = .agentResult

        #expect(defaults?.string(forKey: TrailingPaneState.surfaceKey(connectionId)) == nil)
    }

    @Test("Turning the AI feature off takes every AI surface with it")
    func aiSurfacesFollowTheSetting() {
        #expect(TrailingPaneSurface.resolved(.assistant, isAIEnabled: false) == .inspector)
        #expect(TrailingPaneSurface.resolved(.agentResult, isAIEnabled: false) == .inspector)
        #expect(TrailingPaneSurface.resolved(.assistant, isAIEnabled: true) == .assistant)
    }

    /// A mode switch is one of the three moments the titlebar may change shape, so it has to reach
    /// the key the toolbar compares before it writes anything.
    @Test("A mode switch changes the titlebar's visibility key")
    func modeSwitchChangesTheVisibilityKey() {
        let browse = ToolbarContext(tabKind: .table, contentMode: .browse, isAIEnabled: true)
        let agent = ToolbarContext(tabKind: .table, contentMode: .agent, isAIEnabled: true)
        #expect(browse.visibilityKey != agent.visibilityKey)
    }

    /// Nothing on screen draws a session while browsing, so nothing may be rebuilt after one: a
    /// session started or switched then would otherwise repaint panes nobody is looking at.
    @Test("The displayed agent session, and the render key, name a session only in Agent mode")
    func agentSessionIsNamedOnlyInAgentMode() {
        AIFeatureScope.enabled {
            let registry = AgentSessionRegistry(store: AgentSessionStore(directory: Self.temporaryDirectory()))
            let workspace = Self.makeWorkspace(phase: .idle, agentSessions: registry)
            let session = registry.startSession(for: workspace.connectionId)

            #expect(workspace.displayedAgentSession == nil)
            #expect(workspace.paneRenderKey.agentSessionId == nil)

            workspace.contentMode = .agent

            #expect(workspace.displayedAgentSession === session)
            #expect(workspace.paneRenderKey.agentSessionId == session.id)
        }
    }

    @Test("A workspace reads its sessions from the registry it was given")
    func workspaceReadsItsOwnRegistry() {
        AIFeatureScope.enabled {
            let mine = AgentSessionRegistry(store: AgentSessionStore(directory: Self.temporaryDirectory()))
            let other = AgentSessionRegistry(store: AgentSessionStore(directory: Self.temporaryDirectory()))
            let workspace = Self.makeWorkspace(phase: .idle, agentSessions: mine)
            workspace.contentMode = .agent
            other.startSession(for: workspace.connectionId)

            #expect(workspace.displayedAgentSession == nil)

            let session = mine.startSession(for: workspace.connectionId)
            #expect(workspace.displayedAgentSession === session)
        }
    }

    /// The conversation is what Agent mode draws while the connection is up or coming up, and the
    /// unavailable screen, with its Retry, is what it draws over one that cannot be reached.
    @Test("The detail column follows the mode, except over a connection that cannot be reached")
    func detailModeFollowsTheModeAndThePane() {
        AIFeatureScope.enabled {
            let registry = AgentSessionRegistry(store: AgentSessionStore(directory: Self.temporaryDirectory()))
            let connecting = Self.makeWorkspace(phase: .connecting, agentSessions: registry)
            let failed = Self.makeWorkspace(
                phase: .unavailable(.failed(ConnectionFailureInfo(message: "refused"))),
                agentSessions: registry
            )

            #expect(connecting.detailMode == .browse)
            connecting.contentMode = .agent
            failed.contentMode = .agent
            #expect(connecting.detailMode == .agent)
            #expect(failed.detailMode == .browse)
        }
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentModeTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeWorkspace(
        phase: ConnectionWindowPhase,
        agentSessions: AgentSessionRegistry
    ) -> ConnectionWorkspace {
        let connection = TestFixtures.makeConnection(type: .mysql)
        return ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: phase,
            agentSessions: agentSessions
        )
    }
}
