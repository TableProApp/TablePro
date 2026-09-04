//
//  AgentSession.swift
//  TablePro
//

import Foundation

/// One conversation with the assistant, and everything about it that must outlive the window it was
/// started in.
///
/// The session's identity is the view model's `sessionId`, not a second id of its own. That string
/// is what `ApprovalRequestID` is keyed by and what `ProviderStreamLease` queues on, so a session
/// with an identity of its own would give the rail one id and the approval path another, and a
/// decision made on a rail row would resolve nothing.
@MainActor @Observable
internal final class AgentSession: Identifiable, Equatable {
    internal let id: UUID
    internal let connectionId: UUID

    /// Kept so a stopped session can still name its connection in the rail after the connection's
    /// window is gone and there is no live record to ask.
    internal var connectionName: String

    /// Nil until the transcript has a first user message to take a title from. The rail falls back
    /// to the connection name, which is what a session with no turns yet is best described by.
    internal var title: String?

    internal private(set) var status: AgentSessionStatus
    internal private(set) var createdAt: Date
    internal private(set) var updatedAt: Date

    /// A prompt typed before the connection was ready, held here rather than in the view that
    /// collected it. Welcome can start a session on a connection that takes seconds to dial, and a
    /// prompt owned by a view is lost the moment that view is replaced by the connecting pane.
    internal var pendingPrompt: String?

    /// Which segment the result pane is showing. On the session rather than in the pane's own
    /// `@State`, because the pane is unparented and rebuilt by every mode change, connection switch
    /// and rail selection, and a reader who opened Schema to check a `DROP` should not be returned
    /// to SQL by looking at another connection and coming back.
    internal var artifactSegment: AgentArtifactSegment = .sql

    internal let viewModel: AIChatViewModel

    /// Held rather than reached for, so a status refresh driven by the engine asks the same queue a
    /// caller-supplied refresh does. A test that injected an approval center only at the explicit
    /// call site would still have every engine transition consult the process-wide one.
    @ObservationIgnored private let approvals: ToolApprovalCenter

    /// How a pending prompt reaches the provider. Injectable for the same reason
    /// `AIChatViewModel.streamFlushClock` is: the real path opens a provider request, so a test that
    /// exercised the send would fire one on whatever provider the machine running it has configured.
    @ObservationIgnored internal var promptSender: (String) -> Void

    internal init(
        connectionId: UUID,
        connectionName: String,
        viewModel: AIChatViewModel,
        title: String? = nil,
        status: AgentSessionStatus = .idle,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        approvals: ToolApprovalCenter = .shared,
        promptSender: ((String) -> Void)? = nil
    ) {
        self.approvals = approvals
        self.promptSender = promptSender ?? { [weak viewModel] prompt in
            viewModel?.sendWithContext(prompt: prompt)
        }
        self.id = viewModel.sessionId
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.viewModel = viewModel
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        viewModel.session = self
    }

    internal static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
    }

    /// What the rail puts on the row. The transcript's own title is preferred once there is one,
    /// because two sessions on one connection are otherwise indistinguishable.
    internal var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return connectionName
    }

    /// Why this session is not moving, when it is queued behind another on the same provider.
    internal var statusDetail: String? {
        guard status == .queued else { return nil }
        return viewModel.providerWaitReason
    }

    internal var conversationId: UUID? {
        viewModel.activeConversationID
    }

    /// Recomputes the status from the engine, leaving a terminal one alone.
    ///
    /// A stopped session's engine reads `.idle`, so deriving unconditionally would erase the record
    /// that its window closed on it the first time anything touched the view model. The one thing
    /// that does clear a terminal status is the engine actually working again, which only a send can
    /// cause.
    internal func refreshFromEngine() {
        let derived = Self.derivedStatus(viewModel: viewModel, approvals: approvals)
        if status.isTerminal {
            guard derived == .running || derived == .queued || derived == .waitingOnYou else { return }
        }
        apply(derived)
    }

    /// Pure so the mapping is testable without a provider, a window or a real approval queue.
    internal static func derivedStatus(
        viewModel: AIChatViewModel,
        approvals: ToolApprovalCenter
    ) -> AgentSessionStatus {
        if viewModel.providerWaitReason != nil { return .queued }
        if approvals.hasPending(sessionId: viewModel.sessionId) { return .waitingOnYou }
        switch viewModel.streamingState {
        case .idle:
            return .idle
        case .loading, .streaming:
            return .running
        case .awaitingApproval, .pausedAtToolLimit:
            return .waitingOnYou
        case .failed:
            return .failed
        }
    }

    /// Ends the session's work without touching its transcript.
    ///
    /// Terminal first, then cancel, then persist. The order matters because cancelling is
    /// cooperative: a tool call blocked in a C call cannot be interrupted and completes late, and
    /// what stops it writing into a session that has moved on is finding the session already
    /// terminal. `cancelStream` finalizes the partial turn and persists it, and persisting again
    /// covers a session that was waiting on an approval rather than streaming.
    internal func stop() {
        apply(.stopped)
        viewModel.cancelStream()
        viewModel.persistCurrentConversation()
        viewModel.releaseDerivedContext()
    }

    /// A session that was streaming when the process went away. Recorded rather than restarted: a
    /// tool call that was mid-flight has no result to resume from, and replaying it would run a
    /// statement the user never saw the outcome of.
    internal func markFailed() {
        apply(.failed)
    }

    /// Sends the prompt the session was created with, once its connection is up.
    ///
    /// Cleared before the send is dispatched, not after it completes. A connect can report connected
    /// more than once (a retry, or a second window joining), and clearing afterwards would send the
    /// first turn twice.
    internal func sendPendingPromptIfReady(connection: DatabaseConnection) {
        guard let prompt = pendingPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else {
            pendingPrompt = nil
            return
        }
        pendingPrompt = nil
        viewModel.connection = connection
        connectionName = connection.name
        promptSender(prompt)
    }

    internal func adoptTitleFromTranscript() {
        guard title == nil || title?.isEmpty == true else { return }
        guard let firstUser = viewModel.messages.first(where: { $0.role == .user }) else { return }
        let text = firstUser.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        title = (text as NSString).length > 50 ? String(text.prefix(47)) + "…" : text
    }

    private func apply(_ next: AgentSessionStatus) {
        guard next != status else { return }
        status = next
        updatedAt = Date()
    }
}
