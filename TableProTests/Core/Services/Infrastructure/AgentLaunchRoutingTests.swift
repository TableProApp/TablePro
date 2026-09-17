//
//  AgentLaunchRoutingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Agent launch routing")
@MainActor
struct AgentLaunchRoutingTests {
    /// The welcome window's second way in goes through the one chokepoint every connection intent
    /// takes, so a connection already open is switched where it stands rather than opened twice.
    @Test("An agent intent names the connection it is about")
    func intentCarriesItsConnection() {
        let connectionId = UUID()
        let intent = LaunchIntent.openAgentSession(connectionId: connectionId, prompt: "how many rows?")
        #expect(intent.targetConnectionId == connectionId)
    }

    /// Every intent but the one that starts a server puts something on screen, and the switch has no
    /// `default:` so a new intent has to answer rather than inherit an answer that is wrong for it.
    @Test("An agent intent implies a window")
    func intentImpliesUserInterface() {
        #expect(LaunchIntent.openAgentSession(connectionId: UUID(), prompt: nil).impliesUserInterface)
    }

    @Test("A session holds a prompt typed before it could send it")
    func pendingPromptIsHeld() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLaunchRoutingTests-\(UUID().uuidString)", isDirectory: true)
        let registry = AgentSessionRegistry(store: AgentSessionStore(directory: directory))
        let session = try #require(registry.resolveSession(for: UUID(), startingIfNeeded: true))

        session.pendingPrompt = "which tables are biggest?"
        #expect(session.pendingPrompt == "which tables are biggest?")

        /// Cleared before it is dispatched, which is what lets more than one flush site exist
        /// without the prompt being sent twice.
        let taken = session.pendingPrompt
        session.pendingPrompt = nil
        #expect(taken == "which tables are biggest?")
        #expect(session.pendingPrompt == nil)
    }

    @Test("Opening in agent mode is its own welcome command")
    func welcomeCommandExists() {
        let connectionId = UUID()
        let command = WelcomeMenuCommand.startAgentSession(connectionId)
        #expect(command == .startAgentSession(connectionId))
        #expect(command != .disconnect(connectionId))
    }
}
