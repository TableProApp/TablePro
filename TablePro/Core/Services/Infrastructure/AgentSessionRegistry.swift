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
    }

    private func makeViewModel(sessionId: UUID, conversationId: UUID?) -> AIChatViewModel {
        AIChatViewModel(services: services, sessionId: sessionId, restoringConversation: conversationId)
    }

    // MARK: - Reading

    internal func sessions(for connectionId: UUID) -> [AgentSession] {
        sessions
            .filter { $0.connectionId == connectionId }
            .sorted { $0.startedAt < $1.startedAt }
    }

    internal func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// The session a connection's two presentations share.
    ///
    /// Both the trailing-pane chat and the agent-mode conversation column resolve through here, so
    /// they cannot end up rendering two different sessions of the same connection. Reading never
    /// creates: opening a connection window starts no session and loads no transcript.
    internal func currentSession(for connectionId: UUID) -> AgentSession? {
        let owned = sessions(for: connectionId)
        return owned.first { !$0.status.isEnded } ?? owned.last
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
        persist()
        return session
    }

    /// The session to show for a connection, starting one only when the caller means to.
    @discardableResult
    internal func resolveSession(for connectionId: UUID, startingIfNeeded: Bool) -> AgentSession? {
        if let existing = currentSession(for: connectionId) {
            existing.resume()
            return existing
        }
        guard startingIfNeeded else { return nil }
        return startSession(for: connectionId)
    }

    /// Ends one session and keeps its transcript. The conversation stays in the history.
    internal func stopSession(id: UUID) {
        guard let session = session(id: id) else { return }
        session.stop()
        persist()
    }

    /// Ends every session on a connection. Disconnect and window close reach this; neither is the
    /// user discarding a conversation, so nothing is deleted.
    internal func stopSessions(for connectionId: UUID) {
        let owned = sessions(for: connectionId).filter { !$0.status.isEnded }
        guard !owned.isEmpty else { return }
        for session in owned {
            session.stop()
        }
        persist()
    }

    /// Discards a session and the conversation behind it. Only an explicit user action reaches here.
    internal func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        let conversationId = session.conversationId
        session.viewModel.cancelStream()
        AIProviderFactory.resetCopilotConversation(sessionId: id)
        sessions.remove(at: index)
        if let conversationId {
            let storage = services.aiChatStorage
            Task { await storage.delete(conversationId) }
        }
        persist()
    }

    internal func markActive(id: UUID) {
        session(id: id)?.markActive()
        persist()
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
            session.viewModel.persistCurrentConversation()
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
