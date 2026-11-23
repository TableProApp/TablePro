//
//  AgentSessionRegistry.swift
//  TablePro
//

import Combine
import Foundation
import os

// Owns every agent session, so closing a window or disconnecting never destroys a transcript.
@MainActor
internal final class AgentSessionRegistry: ObservableObject {
    internal static let shared = AgentSessionRegistry()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AgentSessionRegistry")

    @Published internal private(set) var sessions: [AgentSession] = []

    private let store: AgentSessionStore
    private let services: AppServices
    private let makeEngine: AgentSession.EngineFactory

    // One writer: unordered tasks let a stale snapshot land last.
    private var writeTask: Task<Void, Never>?

    // `.nothing` is a state of its own, or a closed last session would stay drawn with a live composer.
    private var displayed: [UUID: DisplayedSession] = [:]

    private enum DisplayedSession: Equatable {
        case session(UUID)
        case nothing
    }

    // The rail observes the registry, not each session, so a session going to work is announced here.
    private var activityCancellables: [UUID: AnyCancellable] = [:]

    // Restored synchronously, before any window exists to mint a second session beside a stored one.
    internal init(
        store: AgentSessionStore = AgentSessionStore(),
        services: AppServices = .live,
        makeEngine: AgentSession.EngineFactory? = nil
    ) {
        self.store = store
        self.services = services
        self.makeEngine = makeEngine ?? { sessionId, conversationId in
            AIChatViewModel(services: services, sessionId: sessionId, restoringConversation: conversationId)
        }
        restore()
    }

    private func restore() {
        let records = store.load()
        guard !records.isEmpty else { return }
        sessions = records.map { AgentSession(record: $0, makeEngine: makeEngine) }
        for session in sessions {
            observeActivity(of: session)
        }
    }

    // `@Published` announces before it stores, so the write reads the stamp on the next turn.
    private func observeActivity(of session: AgentSession) {
        activityCancellables[session.id] = session.$lastActiveAt
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                Task { @MainActor [weak self] in self?.persist() }
            }
    }

    // MARK: - Reading

    // The rail's order. Two stamped in the same instant list the one added last first.
    internal func sessions(for connectionId: UUID) -> [AgentSession] {
        sessions.enumerated()
            .filter { $0.element.connectionId == connectionId }
            .sorted { lhs, rhs in
                guard lhs.element.lastActiveAt != rhs.element.lastActiveAt else {
                    return lhs.offset > rhs.offset
                }
                return lhs.element.lastActiveAt > rhs.element.lastActiveAt
            }
            .map(\.element)
    }

    internal func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    // Falls back to the latest of any, so a window after a relaunch, with every session stopped, carries on.
    internal func currentSession(for connectionId: UUID) -> AgentSession? {
        let owned = sessions(for: connectionId)
        switch displayed[connectionId] {
        case .session(let id)?:
            if let match = owned.first(where: { $0.id == id }) {
                return match
            }
        case .nothing?:
            return nil
        case nil:
            break
        }
        return owned.first { !$0.status.isEnded } ?? owned.first
    }

    internal func setDisplayedSession(_ sessionId: UUID, for connectionId: UUID) {
        guard sessions.contains(where: { $0.id == sessionId && $0.connectionId == connectionId }) else {
            return
        }
        displayed[connectionId] = .session(sessionId)
    }

    // A stopped session is shown only once someone opens it, which resumes it.
    private func handOverDisplay(from session: AgentSession) {
        let next = sessions(for: session.connectionId).first { $0.id != session.id && !$0.status.isEnded }
        displayed[session.connectionId] = next.map { .session($0.id) } ?? .nothing
    }

    // MARK: - Writing

    @discardableResult
    internal func startSession(for connectionId: UUID) -> AgentSession {
        let id = UUID()
        let session = AgentSession(
            id: id,
            connectionId: connectionId,
            viewModel: makeEngine(id, nil)
        )
        sessions.append(session)
        displayed[connectionId] = .session(id)
        observeActivity(of: session)
        persist()
        attachRemoteTools(to: session)
        return session
    }

    @discardableResult
    internal func resolveSession(for connectionId: UUID, startingIfNeeded: Bool) -> AgentSession? {
        if let existing = currentSession(for: connectionId) {
            existing.resume()
            attachRemoteTools(to: existing)
            return existing
        }
        guard startingIfNeeded else { return nil }
        return startSession(for: connectionId)
    }

    @discardableResult
    internal func resolveIdleSession(for connectionId: UUID) -> AgentSession {
        if let current = resolveSession(for: connectionId, startingIfNeeded: false),
           current.viewModelIfLoaded?.isBusy != true {
            return current
        }
        return startSession(for: connectionId)
    }

    // The panes are handed over first, so no window shows the session when its memory is released.
    internal func stopSession(id: UUID) {
        guard let session = session(id: id) else { return }
        let isShown = currentSession(for: session.connectionId) === session
        session.stop()
        detachRemoteTools(from: id)
        if isShown {
            handOverDisplay(from: session)
        }
        session.release()
        persist()
    }

    // A connection can be hosted by two windows, and one of them closing is not the connection going away.
    internal func stopSessionsIfUnhosted(for connectionId: UUID) {
        guard WindowManager.shared.workspaces(for: connectionId).isEmpty else { return }
        stopSessions(for: connectionId)
    }

    // Ended sessions are released too: a failed one, or one stopped while on screen, still holds its transcript.
    internal func stopSessions(for connectionId: UUID) {
        let owned = sessions(for: connectionId)
        let live = owned.filter { !$0.status.isEnded }
        for session in live {
            session.stop()
            detachRemoteTools(from: session.id)
        }
        for session in owned {
            session.release()
        }
        if !live.isEmpty {
            persist()
        }
    }

    // Only an explicit, confirmed user action reaches here.
    internal func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        let isShown = currentSession(for: session.connectionId) === session
        discard(session)
        sessions.remove(at: index)
        if isShown {
            handOverDisplay(from: session)
        }
        persist()
    }

    // A deleted connection, from this Mac or another: nothing can open its sessions again.
    internal func removeSessions(for connectionId: UUID) {
        let owned = sessions.filter { $0.connectionId == connectionId }
        guard !owned.isEmpty else { return }
        for session in owned {
            discard(session)
        }
        sessions.removeAll { $0.connectionId == connectionId }
        displayed[connectionId] = nil
        persist()
    }

    // A session never opened has no engine, so its transcript is deleted from the store directly.
    private func discard(_ session: AgentSession) {
        let conversationId = session.conversationId
        let engine = session.viewModelIfLoaded
        engine?.cancelStream()
        detachRemoteTools(from: session.id)
        AIProviderFactory.resetCopilotConversation(sessionId: session.id)
        activityCancellables[session.id] = nil
        guard let conversationId else { return }
        if let engine {
            engine.deleteStoredConversations([conversationId])
        } else {
            let storage = services.aiChatStorage
            Task { await storage.delete(conversationId) }
        }
    }

    // MARK: - Outside MCP servers

    // Not awaited: a first paint never waits on a remote server. Attaching again keeps a resumed session's tools.
    private func attachRemoteTools(to session: AgentSession) {
        Task { await MCPRemoteToolCoordinator.shared.attach(session: session) }
    }

    // The tools stay registered while another session still holds a server.
    private func detachRemoteTools(from sessionId: UUID) {
        Task { await MCPRemoteToolCoordinator.shared.detach(sessionId: sessionId) }
    }

    // MARK: - Persistence

    internal func persist() {
        let records = sessions.map(\.record)
        let store = store
        writeTask?.cancel()
        writeTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            store.save(records)
        }
    }

    // For a caller that has to know the write landed; `persist()` books it for the next turn.
    internal func persistNow() {
        writeTask?.cancel()
        writeTask = nil
        for session in sessions {
            session.viewModelIfLoaded?.persistCurrentConversationSynchronously()
        }
        store.save(sessions.map(\.record))
    }

    // A hop at terminate may never run. A session still working is recorded as failed: its reply never finished.
    internal func persistSynchronouslyForTermination() {
        for session in sessions where session.status == .working {
            session.mark(.failed)
        }
        persistNow()
    }
}
