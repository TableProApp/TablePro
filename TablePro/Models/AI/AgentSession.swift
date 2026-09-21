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

    /// Hands the pending prompt over once the connection is up, and clears it as it goes.
    ///
    /// The conversation asks from a `task` keyed on the session, the connect and the prompt, and a
    /// reparent re-runs every such task on the same view: a mode toggle and a connection switch are
    /// both one. Taking rather than reading is what keeps each of those re-runs from sending the
    /// prompt a second time.
    internal func takePendingPrompt(isConnecting: Bool) -> String? {
        guard !isConnecting, let prompt = pendingPrompt else { return nil }
        pendingPrompt = nil
        return prompt
    }

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
    /// Republishes the engine's changes, and its turns'.
    ///
    /// A `ChatTurn` is an `ObservableObject` of its own, and appending a tool-use block mutates the
    /// turn rather than the view model's `messages` array, so the view model never announced it.
    /// The result pane could not show a proposed statement until some later top-level change
    /// happened to fire, which for a card waiting on an answer is never.
    private func observeEngine() {
        viewModel.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                Task { @MainActor [weak self] in
                    self?.observeTurns()
                    self?.refreshDerivedState()
                }
            }
            .store(in: &cancellables)
        observeTurns()
    }

    private var turnCancellables: [UUID: AnyCancellable] = [:]

    private func observeTurns() {
        let live = Set(viewModel.messages.map(\.id))
        turnCancellables = turnCancellables.filter { live.contains($0.key) }
        for turn in viewModel.messages where turnCancellables[turn.id] == nil {
            turnCancellables[turn.id] = turn.objectWillChange
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.objectWillChange.send()
                    Task { @MainActor [weak self] in self?.refreshDerivedState() }
                }
        }
    }

    /// Status follows the engine while the session is live. A session the user stopped, or one that
    /// failed, keeps the state it ended on: the engine underneath it is idle either way, and idle
    /// is not the same answer as stopped.
    /// A stopped session keeps the state it ended on; a failed one does not.
    ///
    /// Retry is offered on a failure and moves the engine back through idle, loading and streaming,
    /// so freezing on `.failed` left the rail reporting Failed for the whole of a successful retry
    /// and session resolution still treating it as ended.
    private func refreshDerivedState() {
        let engineStatus = derivedStatus()
        if status != .stopped, status != engineStatus {
            status = engineStatus
        }
        let derivedTitle = derivedTitle()
        if title != derivedTitle {
            title = derivedTitle
        }
    }

    /// Waiting is asked before working, because an ordinary tool card leaves `streamingState` on
    /// `.streaming`: the stream is parked on the answer, not producing. `.awaitingApproval` is the
    /// connection's own AI-access confirmation and is a different question.
    private func derivedStatus() -> AgentSessionStatus {
        if ToolApprovalCenter.shared.hasPending(sessionId: id) { return .waitingOnYou }
        if case .awaitingApproval = viewModel.streamingState { return .waitingOnYou }
        if viewModel.lastMessageFailed { return .failed }
        if viewModel.isStreaming { return .working }
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
        settlePendingApprovals()
        viewModel.persistCurrentConversation()
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

    /// Settles a card that is still waiting before the transcript is written.
    ///
    /// `cancelStream()` resumes the continuation, but the suspended task only marks the block
    /// `.cancelled` once it is back on the main actor, and the snapshot was taken before that. The
    /// restored transcript then held a `.pending` card with no continuation behind it, whose Run
    /// button could never work.
    private func settlePendingApprovals() {
        for turn in viewModel.messages {
            for block in turn.blocks {
                guard case .toolUse(var use) = block.kind,
                      case .pending = use.approvalState else { continue }
                use.approvalState = .cancelled
                block.setKind(.toolUse(use))
            }
        }
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
