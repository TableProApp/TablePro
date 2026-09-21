//
//  AgentSessionRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AgentSessionRegistry")
@MainActor
struct AgentSessionRegistryTests {
    private func makeStore() -> AgentSessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionRegistryTests-\(UUID().uuidString)", isDirectory: true)
        return AgentSessionStore(directory: directory)
    }

    @Test("Reading a connection's sessions never creates one")
    func readingDoesNotCreate() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()

        #expect(registry.currentSession(for: connectionId) == nil)
        #expect(registry.sessions(for: connectionId).isEmpty)
        #expect(registry.resolveSession(for: connectionId, startingIfNeeded: false) == nil)
        #expect(registry.sessions.isEmpty)
    }

    /// One session, two presentations. The trailing-pane chat and the agent-mode conversation column
    /// both resolve through here, so they must land on the same object or the feature is two
    /// conversations wearing one name.
    @Test("Both presentations resolve to the same session")
    func bothPresentationsShareOneSession() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()

        let first = registry.resolveSession(for: connectionId, startingIfNeeded: true)
        let second = registry.resolveSession(for: connectionId, startingIfNeeded: true)

        #expect(first === second)
        #expect(registry.sessions(for: connectionId).count == 1)
    }

    @Test("A session's engine carries the session's own id")
    func engineCarriesSessionId() throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let session = try #require(registry.resolveSession(for: UUID(), startingIfNeeded: true))
        #expect(session.viewModel.sessionId == session.id)
    }

    /// The conversation flushes a held prompt from a `task`, and a reparent re-runs that task on the
    /// same view: a mode toggle and a connection switch are both one. Taking the prompt rather than
    /// reading it is what keeps each re-run from sending it again.
    @Test("A held prompt is handed over once, and only once the connection is up")
    func heldPromptIsTakenOnce() throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let session = try #require(registry.resolveSession(for: UUID(), startingIfNeeded: true))
        session.pendingPrompt = "Which orders shipped late?"

        #expect(session.takePendingPrompt(isConnecting: true) == nil)
        #expect(session.pendingPrompt == "Which orders shipped late?")

        #expect(session.takePendingPrompt(isConnecting: false) == "Which orders shipped late?")
        #expect(session.takePendingPrompt(isConnecting: false) == nil)
        #expect(session.pendingPrompt == nil)
    }

    /// Stopping keeps the transcript. Window close, disconnect and a lost session all reach it, and
    /// none of them is the user throwing a conversation away.
    @Test("Stopping a session keeps it and its transcript")
    func stoppingKeepsTheSession() throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let session = try #require(registry.resolveSession(for: connectionId, startingIfNeeded: true))
        session.viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("keep me")]))

        registry.stopSessions(for: connectionId)

        #expect(session.status == .stopped)
        #expect(session.viewModel.messages.isEmpty == false)
        #expect(registry.sessions(for: connectionId).count == 1)
    }

    @Test("Resolving a stopped session resumes it rather than starting another")
    func resolvingResumesAStoppedSession() throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let session = try #require(registry.resolveSession(for: connectionId, startingIfNeeded: true))
        registry.stopSessions(for: connectionId)

        let resumed = registry.resolveSession(for: connectionId, startingIfNeeded: false)

        #expect(resumed === session)
        #expect(session.status == .ready)
        #expect(registry.sessions(for: connectionId).count == 1)
    }

    @Test("New Session starts a second one on the same connection")
    func startSessionAddsAnother() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()

        registry.startSession(for: connectionId)
        registry.startSession(for: connectionId)

        #expect(registry.sessions(for: connectionId).count == 2)
    }

    @Test("Sessions of other connections are not listed")
    func sessionsAreScopedToTheirConnection() {
        let registry = AgentSessionRegistry(store: makeStore())
        let first = UUID()
        let second = UUID()

        registry.startSession(for: first)
        registry.startSession(for: second)

        #expect(registry.sessions(for: first).count == 1)
        #expect(registry.sessions(for: second).count == 1)
        #expect(registry.sessions.count == 2)
    }

    /// Restore has to finish before any window exists. A window that opened while a load was
    /// suspended found nothing, minted a session, and was then joined by the stored one: two
    /// sessions on one conversation, both persisted, both in the rail.
    @Test("Sessions come back from disk in the registry's own initialiser")
    func restoreIsSynchronous() throws {
        let store = makeStore()
        let connectionId = UUID()
        let sessionId = UUID()
        store.save([
            AgentSessionRecord(
                id: sessionId,
                connectionId: connectionId,
                conversationId: UUID(),
                status: .stopped,
                title: "Earlier work",
                startedAt: Date(timeIntervalSince1970: 1_000),
                lastActiveAt: Date(timeIntervalSince1970: 2_000)
            )
        ])

        let registry = AgentSessionRegistry(store: store)

        let restored = try #require(registry.session(id: sessionId))
        #expect(restored.id == sessionId)
        #expect(restored.connectionId == connectionId)
        #expect(restored.title == "Earlier work")
        #expect(restored.status == .stopped)
        #expect(restored.viewModel.sessionId == sessionId)
    }

    @Test("A restored session keeps its id rather than being minted again")
    func restorePreservesIdentity() throws {
        let store = makeStore()
        let connectionId = UUID()
        let original = AgentSessionRegistry(store: store)
        let started = try #require(original.resolveSession(for: connectionId, startingIfNeeded: true))
        let startedId = started.id
        original.persistNow()

        let reopened = AgentSessionRegistry(store: store)
        let restored = try #require(reopened.currentSession(for: connectionId))

        #expect(restored.id == startedId)
    }

    @Test("Removing a session takes it out of the rail")
    func removingDiscardsTheSession() throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let session = try #require(registry.resolveSession(for: connectionId, startingIfNeeded: true))

        registry.removeSession(id: session.id)

        #expect(registry.sessions(for: connectionId).isEmpty)
        #expect(registry.session(id: session.id) == nil)
    }

    /// A reply that was still arriving when the app went away did not finish, and saying so is more
    /// honest than leaving it reading as busy for ever.
    @Test("A session still working at terminate is recorded as failed")
    func terminationMarksWorkingSessionsFailed() throws {
        let store = makeStore()
        let registry = AgentSessionRegistry(store: store)
        let session = try #require(registry.resolveSession(for: UUID(), startingIfNeeded: true))
        session.mark(.working)

        registry.persistSynchronouslyForTermination()

        #expect(session.status == .failed)
        let records = store.load()
        #expect(records.first?.status == .failed)
    }
}
