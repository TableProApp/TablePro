//
//  AgentSessionRegistry.swift
//  TablePro
//

import Foundation
import os

/// Where sessions live, which is not a window.
///
/// A session used to be a field on the window's right panel, so its lifetime was the window's: two
/// sessions on one connection were unreachable, and closing a window took a transcript with it.
/// Holding them here is what makes several sessions possible and what lets a closed window's
/// session still be listed.
///
/// Read and create are separate calls on purpose. `RightPanelState.aiViewModel` used to be a
/// creating getter read from inside SwiftUI bodies, and a creating read here would mint a phantom
/// session into the rail the moment any connection window rendered, while mutating an observed
/// array during a view update.
@MainActor @Observable
internal final class AgentSessionRegistry {
    internal static let shared = AgentSessionRegistry()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AgentSessionRegistry")

    internal private(set) var sessions: [AgentSession] = []

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let store: AgentSessionStore
    @ObservationIgnored private let approvals: ToolApprovalCenter
    /// How a restored record finds its connection again. Injected rather than reached through
    /// `services.connectionStorage`, so a test can exercise restore without the connection list of
    /// whoever is running it being the fixture.
    @ObservationIgnored private let connectionLookup: (UUID) -> DatabaseConnection?
    @ObservationIgnored private var didRestore = false

    internal init(
        services: AppServices = .live,
        store: AgentSessionStore = .shared,
        approvals: ToolApprovalCenter = .shared,
        connectionLookup: ((UUID) -> DatabaseConnection?)? = nil
    ) {
        self.services = services
        self.store = store
        self.approvals = approvals
        self.connectionLookup = connectionLookup ?? { services.connectionStorage.loadConnection(id: $0) }
        approvals.onPendingChange = { [weak self] sessionId in
            self?.refreshStatus(sessionId: sessionId)
        }
    }

    // MARK: - Reads

    internal func existingSession(id: UUID) -> AgentSession? {
        restoreIfNeeded()
        return sessions.first { $0.id == id }
    }

    internal func sessions(for connectionId: UUID) -> [AgentSession] {
        sessions.filter { $0.connectionId == connectionId }
    }

    /// The session the inspector chat and the assistant surface share for a connection. The most
    /// recently touched non-terminal one, so a connection whose earlier session was stopped by a
    /// window close resolves to the one the user is actually working in.
    internal func existingDefaultSession(for connectionId: UUID) -> AgentSession? {
        let owned = sessions(for: connectionId)
        let live = owned.filter { !$0.status.isTerminal }
        return (live.isEmpty ? owned : live).max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - Create

    /// Takes a connection, not an id. Phase 2 made the connection a creation-time requirement of the
    /// view model so no path can stream with a nil connection, and a registry that accepted an id
    /// would put that back.
    @discardableResult
    internal func makeSession(connection: DatabaseConnection, title: String? = nil) -> AgentSession {
        restoreIfNeeded()
        let viewModel = AIChatViewModel(services: services, connection: connection)
        let session = AgentSession(
            connectionId: connection.id,
            connectionName: connection.name,
            viewModel: viewModel,
            title: title,
            approvals: approvals
        )
        sessions.append(session)
        persist()
        /// Outside MCP servers this connection allows are connected in the background. A server that
        /// never answers must not hold up the session the user just started, so nothing here is
        /// awaited and a failure only means the tools are not offered.
        Task { await MCPRemoteToolCoordinator.shared.attach(session: session) }
        return session
    }

    /// The read-or-create the surfaces use. Never called from a view body: every caller is a user
    /// action (choosing the AI tab, switching to Assistant mode, sending from Welcome) or an
    /// explicit `.task`.
    internal func session(for connection: DatabaseConnection) -> AgentSession {
        restoreIfNeeded()
        if let existing = existingDefaultSession(for: connection.id) {
            existing.connectionName = connection.name
            existing.viewModel.connection = connection
            return existing
        }
        return makeSession(connection: connection)
    }

    // MARK: - Status

    internal func refreshStatus(sessionId: UUID) {
        guard let session = existingSession(id: sessionId) else { return }
        session.refreshFromEngine()
    }

    /// Called when a transcript gains its first user turn, so a rail row stops reading as the
    /// connection's name once there is something better to call it.
    internal func noteActivity(sessionId: UUID) {
        guard let session = existingSession(id: sessionId) else { return }
        session.adoptTitleFromTranscript()
        persist()
    }

    // MARK: - Teardown

    /// A window closing, or a session lost, stops that connection's sessions with their transcripts
    /// intact. Per decision 2 the disconnect path itself is untouched: this runs ahead of it so the
    /// disconnect is correct rather than something to work around.
    internal func stopSessions(for connectionId: UUID) {
        let owned = sessions(for: connectionId)
        guard !owned.isEmpty else { return }
        for session in owned {
            session.stop()
        }
        persist()
    }

    /// `stop()` marks terminal, cancels and persists in that order, so the partial turn is on disk
    /// before the session leaves the list. Dropping first would release the view model every stream
    /// handler holds weakly, and each one would return early instead of finalizing its turn.
    internal func remove(id: UUID) {
        guard let session = existingSession(id: id) else { return }
        session.stop()
        session.viewModel.releaseUnsentAttachments()
        sessions.removeAll { $0.id == id }
        persist()
        /// A server's tools stay registered while another session still authorizes it, so a call
        /// already in flight on that session is untouched.
        Task { await MCPRemoteToolCoordinator.shared.detach(sessionId: id) }
    }

    internal func removeSessions(for connectionId: UUID) {
        let owned = sessions(for: connectionId)
        guard !owned.isEmpty else { return }
        let ids = owned.map(\.id)
        for session in owned {
            session.stop()
            session.viewModel.releaseUnsentAttachments()
        }
        sessions.removeAll { $0.connectionId == connectionId }
        persist()
        Task {
            for id in ids {
                await MCPRemoteToolCoordinator.shared.detach(sessionId: id)
            }
        }
    }

    // MARK: - Persistence

    internal var records: [AgentSessionRecord] {
        sessions.map { session in
            AgentSessionRecord(
                id: session.id,
                connectionId: session.connectionId,
                connectionName: session.connectionName,
                title: session.title,
                status: session.status,
                conversationId: session.conversationId,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
        }
    }

    internal func persist() {
        let snapshot = records
        Task { await store.save(snapshot) }
    }

    /// Quit. A streaming session is marked failed before the list is written, because a record left
    /// `running` on disk is indistinguishable from a crash and would restore as failed anyway; doing
    /// it here means the transcript is saved by the same pass rather than lost.
    internal func persistAtTerminate() {
        for session in sessions where !session.status.isTerminal {
            session.viewModel.persistCurrentConversationSync()
            guard session.status != .idle else { continue }
            session.markFailed()
        }
        store.saveSync(records)
    }

    // MARK: - Restore

    /// Rebuilds the list from disk once per launch, before this registry answers anything.
    ///
    /// Synchronous, and called from every read and every create rather than kicked off at launch.
    /// An asynchronous restore leaves a window between the launch that starts it and the load that
    /// finishes it, and a `session(for:)` in that window finds an empty list, mints a session, and
    /// is then joined by the stored one: two sessions on one conversation, both persisted, both in
    /// the rail. Restoring on first use closes the window by construction and costs launch nothing,
    /// because nothing on the launch path asks the registry a question.
    ///
    /// A record whose connection has since been deleted is dropped rather than restored against a
    /// connection that no longer exists: the session could not be opened, and a row that cannot be
    /// opened is worse than no row.
    internal func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        let stored = store.load()
        guard !stored.isEmpty else { return }
        var restored: [AgentSession] = []
        for record in stored {
            guard let connection = connectionLookup(record.connectionId) else {
                Self.logger.info(
                    "Dropping session \(record.id, privacy: .public); its connection is gone"
                )
                continue
            }
            let viewModel = AIChatViewModel(services: services, connection: connection)
            viewModel.activeConversationID = record.conversationId
            let session = AgentSession(
                connectionId: record.connectionId,
                connectionName: connection.name,
                viewModel: viewModel,
                title: record.title,
                status: record.restoredStatus,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                approvals: approvals
            )
            restored.append(session)
        }
        let adopted = restored.filter { restoredSession in
            !sessions.contains { $0.id == restoredSession.id }
        }
        sessions.append(contentsOf: adopted)
        persist()
        /// Restored sessions authorize their connection's outside MCP servers exactly as a new one
        /// does. Only `makeSession` used to attach, so an allowlisted server's tools were missing
        /// from every session that came back from disk until the user started a fresh one.
        Task {
            for session in adopted {
                await MCPRemoteToolCoordinator.shared.attach(session: session)
            }
        }
    }

    /// Pulls a restored session's turns in on demand. Reading the whole conversation directory for
    /// every restored session at launch would be quadratic in the number of sessions, and a session
    /// nobody opens never needs its turns at all.
    internal func loadTranscript(for session: AgentSession) async {
        guard session.viewModel.messages.isEmpty,
              let conversationId = session.viewModel.activeConversationID
        else { return }
        await session.viewModel.adoptConversation(id: conversationId)
        session.adoptTitleFromTranscript()
    }
}
