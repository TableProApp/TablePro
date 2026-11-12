//
//  AgentSession.swift
//  TablePro
//

import Combine
import Foundation

// Both presentations render this one `AIChatViewModel`, so there is one transcript, draft and scroll position.
@MainActor
internal final class AgentSession: ObservableObject, Identifiable {
    internal let id: UUID
    internal let connectionId: UUID

    internal let viewModel: AIChatViewModel

    @Published internal private(set) var status: AgentSessionStatus
    @Published internal private(set) var title: String

    internal let startedAt: Date

    // The rail's order. Opening a session is not work, or a row would jump from under the pointer.
    @Published internal private(set) var lastActiveAt: Date

    // The result column is one hosting controller per window, so state kept there leaks between sessions.
    @Published internal var resultSegment: AgentResultSegment = .sql

    internal var pendingPrompt: String?

    // A reparent re-runs the task that asks for this, so taking rather than reading sends it once.
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

    // A session restored from disk or released holds its conversation's id before its transcript.
    internal var conversationId: UUID? {
        viewModel.activeConversationID ?? viewModel.conversationToRestore
    }

    internal var displayTitle: String {
        title.isEmpty ? String(localized: "New Session") : title
    }

    // A tool-use block mutates its turn rather than `messages`, so each turn is observed as well.
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

    // A failed session follows the engine, since Retry moves it back through streaming.
    private func refreshDerivedState() {
        let engineStatus = derivedStatus()
        if status != .stopped, status != engineStatus {
            if engineStatus == .working {
                markActive()
            }
            status = engineStatus
        }
        // Empty lists say nothing about the title of a transcript that is not read yet.
        guard !viewModel.isAwaitingTranscript else { return }
        let derivedTitle = derivedTitle()
        if title != derivedTitle {
            title = derivedTitle
        }
    }

    // A tool card leaves `streamingState` on `.streaming` while the stream waits on the answer.
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

    // None of the callers is the user throwing a conversation away, so the transcript is written first.
    internal func stop() {
        viewModel.cancelStream()
        viewModel.persistCurrentConversation()
        mark(.stopped)
    }

    // Only once no window shows the session; its next showing reads back from disk what this drops.
    internal func release() {
        viewModel.releaseLoadedState()
    }

    // Nothing is replayed: a statement waiting for an answer was cancelled by the stop.
    internal func resume() {
        guard status.isEnded else { return }
        mark(.ready)
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

// Points at a conversation rather than copying its turns, so the transcript has one home.
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
