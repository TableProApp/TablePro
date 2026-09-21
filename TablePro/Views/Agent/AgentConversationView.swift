//
//  AgentConversationView.swift
//  TablePro
//

import SwiftUI

/// The session's conversation, in the window's content area.
///
/// It is `AIChatPanelView`, the same view the trailing pane uses, rather than a second chat surface.
/// That is what "one session, two presentations" means in practice: the transcript, the composer
/// draft and the provider picker are the session's, so switching mode changes how the conversation
/// is presented and nothing about the conversation. What it does change is the width: the pane fills
/// its 270pt column, and here the transcript and the composer take a reading measure and leave the
/// rest of the window as margin.
internal struct AgentConversationView: View {
    internal let connection: DatabaseConnection
    internal let session: AgentSession?
    internal let isConnecting: Bool
    /// What is holding Safe Mode above the level the connection is set to, which in this mode is
    /// always something: the mode raises one of its own.
    internal let safeModeFloor: SafeModeFloor?
    internal let onStartSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isConnecting {
                connectingNotice
                Divider()
            }
            if let session {
                AgentConversationContextStrip(
                    connectionName: connection.name,
                    session: session,
                    safeModeFloor: safeModeFloor
                )
                Divider()
                AIChatPanelView(
                    connection: connection,
                    viewModel: session.viewModel,
                    contentWidth: .reading
                )
                /// A prompt typed before the connection landed is sent once, here, when the session
                /// can take it. It is cleared before it is dispatched, so a second flush site cannot
                /// send it again.
                .task(id: session.id) {
                    /// The restore is otherwise reached only through `AssistantState.activate`, so a
                    /// session whose first presentation is Agent mode came back with an empty
                    /// transcript and started a second conversation on the next message.
                    if session.viewModel.connection?.id != connection.id {
                        session.viewModel.connection = connection
                    }
                    session.viewModel.restoreConversationsIfNeeded()
                }
                .task(id: flushKey(session)) {
                    session.viewModel.isAwaitingConnection = isConnecting
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
        guard let prompt = session.takePendingPrompt(isConnecting: isConnecting) else { return }
        session.viewModel.inputText = prompt
        session.viewModel.sendMessage()
    }

    /// Named rather than spun. A connect the user can see is a connect they can type through, so the
    /// composer below stays live and what they type is held by the engine and streamed when the
    /// session lands.
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
            Label(String(localized: "No Session Open"), systemImage: "sparkles")
        } description: {
            Text(String(localized: "Start one to ask about this connection."))
        } actions: {
            Button(String(localized: "New Session"), action: onStartSession)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The line above the transcript that says what this conversation is about.
///
/// The connection and the session each on a label of their own, secondary for the session, rather
/// than joined by a separator: a middle dot between them reads as generated and gives a screen reader
/// nothing to pause on. The rest of the line is the Safe Mode floor, as the level's own symbol and
/// the reason in a few words, with the sentence behind it as the tooltip and as what VoiceOver reads.
/// Agent mode raises that floor on every connection it is on and used to say so nowhere.
private struct AgentConversationContextStrip: View {
    let connectionName: String
    @ObservedObject var session: AgentSession
    let safeModeFloor: SafeModeFloor?

    var body: some View {
        HStack(spacing: 8) {
            Text(connectionName)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(session.displayTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if let safeModeFloor {
                floorLabel(safeModeFloor)
            }
        }
        .font(.callout)
        /// Capped before the padding, so the strip's leading edge is the transcript's own rather than
        /// a padding's width to the right of it.
        .chatColumn(.reading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func floorLabel(_ floor: SafeModeFloor) -> some View {
        Label(floor.summary, systemImage: floor.level.iconName)
            .font(.caption)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(1)
            .help(floor.explanation)
            .accessibilityLabel(floor.explanation)
    }
}
