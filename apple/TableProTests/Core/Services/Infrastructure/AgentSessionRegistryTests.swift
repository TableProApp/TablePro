//
//  AgentSessionRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

    // A reparent re-runs the task that flushes the prompt, so taking it is what sends it once.
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

    // The transcript leaves memory and stays on disk under the id the session still names.
    @Test("Stopping a session keeps it and its transcript")
    func stoppingKeepsTheSession() async throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let session = try #require(registry.resolveSession(for: connectionId, startingIfNeeded: true))
        session.viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("keep me")]))

        registry.stopSessions(for: connectionId)

        #expect(session.status == .stopped)
        #expect(registry.sessions(for: connectionId).count == 1)
        let conversationId = try #require(session.conversationId)
        await session.viewModel.lastConversationWrite?.value
        let stored = await AIChatStorage.shared.load(id: conversationId)
        let storedTexts = stored?.messages.map { $0.plainText }
        #expect(storedTexts == ["keep me"])
        #expect(session.viewModel.messages.isEmpty)
        await AIChatStorage.shared.delete(conversationId)
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

    // A window opened while a load was suspended minted a second session beside the stored one.
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

    // Its record used to be written with no conversation, so the next launch reopened it empty.
    @Test("A restored session that was never opened keeps its conversation across a save")
    func unopenedSessionKeepsItsConversation() throws {
        let store = makeStore()
        let conversationId = UUID()
        store.save([
            AgentSessionRecord(
                id: UUID(),
                connectionId: UUID(),
                conversationId: conversationId,
                status: .stopped,
                title: "Earlier work",
                startedAt: Date(timeIntervalSince1970: 1_000),
                lastActiveAt: Date(timeIntervalSince1970: 2_000)
            )
        ])
        let registry = AgentSessionRegistry(store: store)

        registry.startSession(for: UUID())
        registry.persistNow()

        let records = store.load()
        #expect(records.count == 2)
        #expect(records.contains { $0.conversationId == conversationId && $0.title == "Earlier work" })
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

    // MARK: - Order

    // Opening is not work, or the row double-clicked would jump from under the pointer.
    @Test("The rail lists the session that last went to work first")
    func sessionsAreOrderedByActivity() throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let first = registry.startSession(for: connectionId)
        let second = registry.startSession(for: connectionId)
        #expect(registry.sessions(for: connectionId).map(\.id) == [second.id, first.id])

        first.markActive()

        #expect(registry.sessions(for: connectionId).map(\.id) == [first.id, second.id])
    }

    @Test("Opening a session leaves the order alone")
    func openingDoesNotReorder() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let first = registry.startSession(for: connectionId)
        let second = registry.startSession(for: connectionId)

        registry.setDisplayedSession(first.id, for: connectionId)

        #expect(registry.sessions(for: connectionId).map(\.id) == [second.id, first.id])
        #expect(registry.currentSession(for: connectionId) === first)
    }

    @Test("The shared session is the latest live one")
    func currentSessionPrefersTheLatestLiveOne() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let first = registry.startSession(for: connectionId)
        let second = registry.startSession(for: connectionId)
        registry.stopSession(id: second.id)

        #expect(registry.currentSession(for: connectionId) === first)
    }

    // MARK: - Closing and deleting the session on screen

    @Test("Closing the session on screen hands the window the next live one")
    func closingHandsOverToTheNextLiveSession() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let first = registry.startSession(for: connectionId)
        let second = registry.startSession(for: connectionId)
        #expect(registry.currentSession(for: connectionId) === second)

        registry.stopSession(id: second.id)

        #expect(second.status == .stopped)
        #expect(registry.currentSession(for: connectionId) === first)
        #expect(registry.sessions(for: connectionId).count == 2, "A closed session stays in the rail")
    }

    @Test("Closing the last live session leaves the window with none")
    func closingTheLastLiveSessionShowsNothing() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let session = registry.startSession(for: connectionId)

        registry.stopSession(id: session.id)

        #expect(registry.currentSession(for: connectionId) == nil)
        #expect(registry.sessions(for: connectionId).count == 1)
    }

    @Test("A window with no session open starts one when it is asked to")
    func resolvingAfterClosingStartsAnother() throws {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let closed = registry.startSession(for: connectionId)
        registry.stopSession(id: closed.id)

        #expect(registry.resolveSession(for: connectionId, startingIfNeeded: false) == nil)
        let started = try #require(registry.resolveSession(for: connectionId, startingIfNeeded: true))

        #expect(started !== closed)
        #expect(registry.currentSession(for: connectionId) === started)
    }

    @Test("Deleting the session on screen hands the window the next live one")
    func deletingHandsOverToTheNextLiveSession() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let first = registry.startSession(for: connectionId)
        let second = registry.startSession(for: connectionId)

        registry.removeSession(id: second.id)

        #expect(registry.currentSession(for: connectionId) === first)
        #expect(registry.sessions(for: connectionId).map(\.id) == [first.id])
    }

    @Test("Deleting a session nobody is looking at leaves the open one alone")
    func deletingAnotherSessionKeepsTheOpenOne() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let other = registry.startSession(for: connectionId)
        let open = registry.startSession(for: connectionId)

        registry.removeSession(id: other.id)

        #expect(registry.currentSession(for: connectionId) === open)
    }

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

    @Test("An explicit action runs in the session on screen while it is idle")
    func idleSessionTakesTheAction() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let current = registry.startSession(for: connectionId)

        let resolved = registry.resolveIdleSession(for: connectionId)

        #expect(resolved === current)
        #expect(registry.sessions(for: connectionId).count == 1)
    }

    @Test("An explicit action beside a busy session starts a new one and leaves the busy one running")
    func busySessionIsLeftRunning() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let busy = registry.startSession(for: connectionId)
        let assistantID = UUID()
        busy.viewModel.streamingState = .streaming(assistantID: assistantID)

        let resolved = registry.resolveIdleSession(for: connectionId)

        #expect(resolved !== busy)
        #expect(registry.currentSession(for: connectionId) === resolved)
        #expect(registry.sessions(for: connectionId).contains { $0 === busy })
        #expect(!busy.status.isEnded)
        guard case .streaming(let streamingID) = busy.viewModel.streamingState else {
            Issue.record("The busy session's reply was cancelled")
            return
        }
        #expect(streamingID == assistantID)
    }

    @Test("A paused tool loop is not busy, so the action takes its session")
    func pausedSessionTakesTheAction() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()
        let paused = registry.startSession(for: connectionId)
        paused.viewModel.streamingState = .pausedAtToolLimit(count: 25)

        #expect(registry.resolveIdleSession(for: connectionId) === paused)
    }

    @Test("An explicit action with no session on screen starts one")
    func actionStartsTheFirstSession() {
        let registry = AgentSessionRegistry(store: makeStore())
        let connectionId = UUID()

        let resolved = registry.resolveIdleSession(for: connectionId)

        #expect(registry.currentSession(for: connectionId) === resolved)
    }
}
