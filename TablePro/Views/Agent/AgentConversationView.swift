//
//  AgentConversationView.swift
//  TablePro
//

import SwiftUI

/// The session's conversation, at the width of the window's content area.
///
/// It is `AIChatPanelView`, the same view the trailing pane uses, rather than a second chat surface.
/// That is what "one session, two presentations" means in practice: the transcript, the composer
/// draft and the provider picker are the session's, so switching mode changes how the conversation
/// is presented and nothing about the conversation.
internal struct AgentConversationView: View {
    internal let connection: DatabaseConnection
    internal let session: AgentSession?
    internal let isConnecting: Bool
    internal let onStartSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isConnecting {
                connectingNotice
                Divider()
            }
            if let session {
                AIChatPanelView(
                    connection: connection,
                    viewModel: session.viewModel
                )
                /// A prompt typed before the connection landed is sent once, here, when the session
                /// can take it. It is cleared before it is dispatched, so a second flush site cannot
                /// send it again.
                .task(id: flushKey(session)) {
                    sendPendingPromptIfReady(session)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The prompt is dispatched when the session exists and nothing is in flight. Keyed on both, so
    /// a connect that lands after the view is already on screen still flushes.
    private func flushKey(_ session: AgentSession) -> String {
        "\(session.id)-\(isConnecting)-\(session.pendingPrompt != nil)"
    }

    private func sendPendingPromptIfReady(_ session: AgentSession) {
        guard !isConnecting, let prompt = session.pendingPrompt else { return }
        session.pendingPrompt = nil
        session.viewModel.inputText = prompt
        session.viewModel.sendMessage()
    }

    /// Named rather than spun. A connect the user can see is a connect they can type through, so the
    /// composer below stays live and what they type is sent when the session lands.
    private var connectingNotice: some View {
        HStack(spacing: 8) {
            DelayedProgressIndicator(isActive: true)
            Text(String(format: String(localized: "Connecting to %@"), connection.name))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        UnavailableStateView {
            Label(String(localized: "No session open"), systemImage: "sparkles")
        } description: {
            Text(String(localized: "Start one to ask about this connection."))
        } actions: {
            Button(String(localized: "New Session"), action: onStartSession)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
