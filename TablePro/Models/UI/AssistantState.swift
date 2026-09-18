//
//  AssistantState.swift
//  TablePro
//

import Combine
import Foundation

/// The assistant surface's own state, for one connection.
///
/// It does not own a session. `AgentSessionRegistry` does, so a session outlives the window: the
/// trailing-pane chat in Browse mode and the conversation column in Agent mode resolve through the
/// same registry and therefore render the same transcript, composer draft and scroll position.
///
/// Nothing here creates a session by being read. Activation is still the single door, and only
/// revealing the surface or invoking an assistant command opens it, because starting one loads a
/// transcript off disk and an unopened assistant should cost nothing.
@MainActor
internal final class AssistantState: ObservableObject {
    @Published internal var context: AssistantContext = .empty

    private let connectionId: UUID?
    private let registry: AgentSessionRegistry

    @Published internal private(set) var isActivated = false

    private var sessionCancellable: AnyCancellable?

    internal init(connectionId: UUID? = nil, registry: AgentSessionRegistry = .shared) {
        self.connectionId = connectionId
        self.registry = registry
    }

    /// The session this connection is showing, or nil when none has been opened.
    ///
    /// Readers that only want to talk to a live assistant take this and do nothing when it is nil,
    /// rather than bringing one into existence.
    internal var session: AgentSession? {
        guard let connectionId else { return nil }
        return registry.currentSession(for: connectionId)
    }

    internal var viewModelIfActivated: AIChatViewModel? {
        session?.viewModel
    }

    /// Opens the connection's session, starting one on first use, and returns its engine.
    ///
    /// The connection is bound before the transcript is restored. `AIChatPanelView.onAppear` used
    /// to be the only writer of `viewModel.connection`, and it runs after this, so the restore ran
    /// with no connection and pulled in every connection's history: another connection's
    /// conversations appeared in the list, and Clear Recents would then have deleted them.
    @discardableResult
    internal func activate(connection: DatabaseConnection? = nil) -> AIChatViewModel? {
        guard let connectionId else { return nil }
        guard let session = registry.resolveSession(for: connectionId, startingIfNeeded: true) else {
            return nil
        }
        if let connection, session.viewModel.connection?.id != connection.id {
            session.viewModel.connection = connection
        }
        session.viewModel.restoreConversationsIfNeeded()
        observe(session)
        if !isActivated { isActivated = true }
        return session.viewModel
    }

    private func observe(_ session: AgentSession) {
        sessionCancellable = session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Releases this presentation. It does not stop the session.
    ///
    /// A connection can be hosted by two windows, each with its own `AssistantState`, while the
    /// registry holds one session between them. Stopping the session here would end a conversation
    /// still on screen, or still streaming, in the other window. Ending a session belongs to the
    /// connection going away, which `AgentSessionRegistry.stopSessions(for:)` is called for from
    /// there.
    internal func teardown() {
        sessionCancellable = nil
        context = .empty
        isActivated = false
    }
}
