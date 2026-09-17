//
//  AgentSession.swift
//  TablePro
//

import Combine
import Foundation

/// One conversation with the assistant about one connection.
///
/// A session outlives the window that opened it. Closing a window stops its sessions and keeps
/// their transcripts; opening one again continues where it stopped, and nothing is replayed.
///
/// It owns exactly one `AIChatViewModel`, which is what makes "one session, two presentations"
/// true: the trailing-pane chat in Browse mode and the conversation column in Agent mode render
/// this same view model, so there is one transcript, one composer draft and one scroll position
/// however the user is looking at it.
@MainActor
internal final class AgentSession: ObservableObject, Identifiable {
    internal let id: UUID
    internal let connectionId: UUID

    /// The engine. Built with this session's id so a restored session is the same session rather
    /// than a new one wearing its transcript.
    internal let viewModel: AIChatViewModel

    @Published internal private(set) var status: AgentSessionStatus
    @Published internal private(set) var title: String

    /// When the session was first opened, which is what the rail orders by.
    internal let startedAt: Date
    internal private(set) var lastActiveAt: Date

    /// Text typed before the session could send it, which a connect long enough to notice a typo in
    /// needs. Cleared before it is dispatched so three flush sites still send once.
    internal var pendingPrompt: String?

    private var cancellables: Set<AnyCancellable> = []

    internal init(
        id: UUID = UUID(),
        connectionId: UUID,
        viewModel: AIChatViewModel,
        status: AgentSessionStatus = .ready,
        title: String = "",
        startedAt: Date = Date(),
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.connectionId = connectionId
        self.viewModel = viewModel
        self.status = status
        self.title = title
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        observeEngine()
    }

    /// The conversation this session's transcript is stored under, or nil before the first reply.
    internal var conversationId: UUID? {
        viewModel.activeConversationID
    }

    /// Republishes the engine's changes as the session's own, so a rail row bound to the session
    /// redraws when the transcript moves. `AIChatViewModel` is an `ObservableObject` of its own and
    /// nothing else forwards it.
    private func observeEngine() {
        viewModel.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                Task { @MainActor [weak self] in self?.refreshDerivedState() }
            }
            .store(in: &cancellables)
    }

    /// Status follows the engine while the session is live. A session the user stopped, or one that
    /// failed, keeps the state it ended on: the engine underneath it is idle either way, and idle
    /// is not the same answer as stopped.
    private func refreshDerivedState() {
        let engineStatus = derivedStatus()
        if !status.isEnded, status != engineStatus {
            status = engineStatus
        }
        let derivedTitle = derivedTitle()
        if title != derivedTitle {
            title = derivedTitle
        }
    }

    private func derivedStatus() -> AgentSessionStatus {
        if viewModel.lastMessageFailed { return .failed }
        if viewModel.isStreaming { return .working }
        if case .awaitingApproval = viewModel.streamingState { return .waitingOnYou }
        if ToolApprovalCenter.shared.hasPending { return .waitingOnYou }
        return .ready
    }

    private func derivedTitle() -> String {
        if let conversationTitle = viewModel.conversations
            .first(where: { $0.id == viewModel.activeConversationID })?.title,
            !conversationTitle.isEmpty {
            return conversationTitle
        }
        let firstUserText = viewModel.messages
            .first { $0.role == .user }?
            .plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstUserText, !firstUserText.isEmpty else { return "" }
        return (firstUserText as NSString).length > 50
            ? String(firstUserText.prefix(47)) + "…"
            : firstUserText
    }

    internal func markActive() {
        lastActiveAt = Date()
    }

    internal func mark(_ newStatus: AgentSessionStatus) {
        guard status != newStatus else { return }
        status = newStatus
    }

    /// Ends the session without touching what it said.
    ///
    /// Window close, disconnect and a lost session all reach here, and none of them is the user
    /// throwing a conversation away, so the transcript is written first and kept.
    internal func stop() {
        viewModel.cancelStream()
        mark(.stopped)
    }

    /// Puts a stopped session back to work. Nothing is replayed: a statement that was waiting for an
    /// answer when the window closed was cancelled by the stop, and the model is asked again rather
    /// than the call being re-issued behind the user's back.
    internal func resume() {
        guard status.isEnded else { return }
        mark(.ready)
        markActive()
    }

    internal var record: AgentSessionRecord {
        AgentSessionRecord(
            id: id,
            connectionId: connectionId,
            conversationId: conversationId,
            status: status.isEnded ? status : .stopped,
            title: title,
            startedAt: startedAt,
            lastActiveAt: lastActiveAt
        )
    }
}

/// What a session is on disk. It points at a conversation rather than copying its turns, so the
/// transcript has one home and a restored session cannot disagree with it.
internal struct AgentSessionRecord: Codable, Equatable, Identifiable, Sendable {
    internal static let currentSchemaVersion = 1

    internal let id: UUID
    internal let connectionId: UUID
    internal let conversationId: UUID?
    internal let status: AgentSessionStatus
    internal let title: String
    internal let startedAt: Date
    internal let lastActiveAt: Date
    internal let schemaVersion: Int

    internal init(
        id: UUID,
        connectionId: UUID,
        conversationId: UUID?,
        status: AgentSessionStatus,
        title: String,
        startedAt: Date,
        lastActiveAt: Date,
        schemaVersion: Int = AgentSessionRecord.currentSchemaVersion
    ) {
        self.id = id
        self.connectionId = connectionId
        self.conversationId = conversationId
        self.status = status
        self.title = title
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.schemaVersion = schemaVersion
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        connectionId = try container.decode(UUID.self, forKey: .connectionId)
        conversationId = try container.decodeIfPresent(UUID.self, forKey: .conversationId)
        status = try container.decodeIfPresent(AgentSessionStatus.self, forKey: .status) ?? .stopped
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? startedAt
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        schemaVersion = max(storedVersion, Self.currentSchemaVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case id, connectionId, conversationId, status, title, startedAt, lastActiveAt, schemaVersion
    }
}
