//
//  AgentSessionRegistry.swift
//  TablePro
//

import Combine
import Foundation
import os

/// Every agent session the app is holding, for as long as the app is running.
///
/// Sessions used to be reached through a field on the window's trailing pane, which made a
/// session's lifetime the window's: closing a window, disconnecting, or losing a session each
/// destroyed a transcript the user never asked to lose. They live here instead, so a window is one
/// of the places a session can be looked at rather than the thing that owns it.
@MainActor
internal final class AgentSessionRegistry: ObservableObject {
    internal static let shared = AgentSessionRegistry()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AgentSessionRegistry")

    @Published internal private(set) var sessions: [AgentSession] = []

    private let store: AgentSessionStore
    private let services: AppServices

    /// Serialises writes. `persist()` used to fire an unordered task per mutation, and actor
    /// reentrancy let a stale snapshot land last.
    private var writeTask: Task<Void, Never>?

    /// Which session each connection is showing.
    ///
    /// Held explicitly rather than derived. Deriving it from `sessions(for:)` answered the oldest
    /// one every time, so New Session appended a row nothing switched to and Open Session moved a
    /// timestamp nothing read: both panes stayed bound to the first session for ever.
    ///
    /// Showing nothing is a state of its own. Closing or deleting the session on screen with no other
    /// live one to hand to used to fall back to the last session in the list, which was the one just
    /// closed, so the column went on drawing a stopped session with a composer that still took
    /// messages.
    private var displayed: [UUID: DisplayedSession] = [:]

    private enum DisplayedSession: Equatable {
        case session(UUID)
        case nothing
    }

    /// Going to work moves a session up the rail, and the rail observes this registry rather than
    /// each session, so the registry has to say so, and write the new stamp so the order survives a
    /// relaunch.
    private var activityCancellables: [UUID: AnyCancellable] = [:]

    /// Restore runs here, synchronously, which is the whole point of the store being a plain struct.
    /// A window that opens while a load is suspended finds nothing, mints a session, and is then
    /// joined by the stored one; doing it in the initialiser means no window can exist yet.
    internal init(store: AgentSessionStore = AgentSessionStore(), services: AppServices = .live) {
        self.store = store
        self.services = services
        restore()
    }

    private func restore() {
        let records = store.load()
        guard !records.isEmpty else { return }
        sessions = records.map { record in
            AgentSession(
                id: record.id,
                connectionId: record.connectionId,
                viewModel: makeViewModel(sessionId: record.id, conversationId: record.conversationId),
                status: record.status.isEnded ? record.status : .stopped,
                title: record.title,
                startedAt: record.startedAt,
                lastActiveAt: record.lastActiveAt
            )
        }
        for session in sessions {
            observeActivity(of: session)
        }
    }

    /// `@Published` announces a change before it is stored, so the write waits for the next turn to
    /// read the new stamp rather than the one it replaces.
    private func observeActivity(of session: AgentSession) {
        activityCancellables[session.id] = session.$lastActiveAt
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                Task { @MainActor [weak self] in self?.persist() }
            }
    }

    private func makeViewModel(sessionId: UUID, conversationId: UUID?) -> AIChatViewModel {
        AIChatViewModel(services: services, sessionId: sessionId, restoringConversation: conversationId)
    }

    // MARK: - Reading

    /// A connection's sessions, the one that last went to work first, which is the order the rail
    /// lists them in. Two stamped in the same instant keep the order they were added in, newest first.
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

    /// The session a connection's two presentations share.
    ///
    /// Both the trailing-pane chat and the agent-mode conversation column resolve through here, so
    /// they cannot end up rendering two different sessions of the same connection. Reading never
    /// creates: opening a connection window starts no session and loads no transcript.
    ///
    /// With nothing named it is the latest live session, then the latest of any, which is how a
    /// window opened after a relaunch, where every session comes back stopped, carries on with the
    /// last one rather than starting another.
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

    /// Names the session a connection's two panes render. The pane render key carries it, so a
    /// switch repaints rather than comparing equal.
    internal func setDisplayedSession(_ sessionId: UUID, for connectionId: UUID) {
        guard sessions.contains(where: { $0.id == sessionId && $0.connectionId == connectionId }) else {
            return
        }
        displayed[connectionId] = .session(sessionId)
    }

    /// Shows the latest live session in place of one that is ending or going away, and nothing when
    /// no other live one is left. A stopped session is shown only once someone opens it, which
    /// resumes it.
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
            viewModel: makeViewModel(sessionId: id, conversationId: nil)
        )
        sessions.append(session)
        displayed[connectionId] = .session(id)
        observeActivity(of: session)
        persist()
        attachRemoteTools(to: session)
        return session
    }

    /// The session to show for a connection, starting one only when the caller means to.
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

    /// Ends one session and keeps its transcript. The conversation stays in the history and the
    /// session stays in the rail, to be opened again.
    ///
    /// The session on screen is handed over as it stops, which is what Close Session means. Nothing
    /// used to tell the panes, so they went on drawing a stopped session with a live composer.
    internal func stopSession(id: UUID) {
        guard let session = session(id: id) else { return }
        let isShown = currentSession(for: session.connectionId) === session
        session.stop()
        detachRemoteTools(from: id)
        if isShown {
            handOverDisplay(from: session)
        }
        persist()
    }

    /// Ends every session on a connection once nothing is showing it any more.
    ///
    /// Called from the connection's own teardown rather than from a window's, because a connection
    /// can be hosted by two windows and one of them closing is not the connection going away.
    internal func stopSessionsIfUnhosted(for connectionId: UUID) {
        guard WindowManager.shared.workspaces(for: connectionId).isEmpty else { return }
        stopSessions(for: connectionId)
    }

    /// Ends every session on a connection. Disconnect and window close reach this; neither is the
    /// user discarding a conversation, so nothing is deleted.
    internal func stopSessions(for connectionId: UUID) {
        let owned = sessions(for: connectionId).filter { !$0.status.isEnded }
        guard !owned.isEmpty else { return }
        for session in owned {
            session.stop()
            detachRemoteTools(from: session.id)
        }
        persist()
    }

    /// Discards a session and the conversation behind it. Only an explicit user action reaches here,
    /// and it has been asked to confirm by then.
    internal func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        let isShown = currentSession(for: session.connectionId) === session
        let conversationId = session.conversationId
        session.viewModel.cancelStream()
        detachRemoteTools(from: id)
        AIProviderFactory.resetCopilotConversation(sessionId: id)
        activityCancellables[id] = nil
        sessions.remove(at: index)
        if isShown {
            handOverDisplay(from: session)
        }
        if let conversationId {
            let storage = services.aiChatStorage
            Task { await storage.delete(conversationId) }
        }
        persist()
    }

    // MARK: - Outside MCP servers

    /// Connects the outside MCP servers this session's connection allows, and registers their tools.
    ///
    /// Started rather than awaited. A server on the other side of a network is not something a
    /// session's first paint may wait on, and a session with no remote tools yet is a session the
    /// model simply has not been offered them in; they appear on the turn after they land.
    ///
    /// Attaching an already-attached session is how a resumed one keeps its tools, so this is safe
    /// to call on every resolve.
    private func attachRemoteTools(to session: AgentSession) {
        Task { await MCPRemoteToolCoordinator.shared.attach(session: session) }
    }

    /// Drops this session's claim on every server. The tools stay registered while another session
    /// still holds one, so ending one conversation cannot take them from another mid-turn.
    private func detachRemoteTools(from sessionId: UUID) {
        Task { await MCPRemoteToolCoordinator.shared.detach(sessionId: sessionId) }
    }

    // MARK: - Persistence

    /// One writer, so the last snapshot taken is the last one written.
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

    /// Writes now, on this thread, and returns once it is on disk.
    ///
    /// `persist()` books the write for the next turn, which is right for an ordinary mutation and
    /// wrong for anything that has to know the write landed.
    internal func persistNow() {
        writeTask?.cancel()
        writeTask = nil
        for session in sessions {
            session.viewModel.persistCurrentConversationSynchronously()
        }
        store.save(sessions.map(\.record))
    }

    /// Writes on the way out.
    ///
    /// An actor hop at terminate may never be scheduled, so a session killed mid-reply used to come
    /// back with its last turn missing. A session still working when the app went away is recorded
    /// as failed, because it was: its reply never finished.
    internal func persistSynchronouslyForTermination() {
        for session in sessions where session.status == .working {
            session.mark(.failed)
        }
        persistNow()
    }
}
