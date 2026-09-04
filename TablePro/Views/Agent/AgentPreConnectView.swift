//
//  AgentPreConnectView.swift
//  TablePro
//

import SwiftUI

/// The assistant surface before the connection answers.
///
/// A prompt typed at the welcome window has to survive a connect that takes seconds and a connect
/// that fails, so it is visible here rather than held somewhere the user cannot see. The failure is
/// inline with **Try Again**, never an alert: the HIG rules alerts out at startup, and N restored
/// connections would mean N modals.
///
/// The transcript and the composer are the same ones the connected panel uses, `AIChatMessageView`
/// and `ChatComposerView`. A second renderer here drew every turn as one unstyled paragraph and a
/// hand-built rectangle that looked like a text field but took no text, so the surface changed
/// appearance the instant the connection landed and the prompt could not be corrected while the
/// user watched it wait. What this surface leaves out is what genuinely needs a live connection:
/// retry, regenerate, the model picker and the tool cards.
internal struct AgentPreConnectView: View {
    internal let connection: DatabaseConnection
    internal let session: AgentSession
    internal let failure: ConnectionUnavailableReason?
    internal let onRetry: () -> Void
    internal let onCancel: () -> Void

    @State private var mentionState = MentionPopoverState()

    internal var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            status
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var transcript: some View {
        if session.viewModel.messages.isEmpty {
            EmptyStateView(
                icon: "sparkles",
                title: String(format: String(localized: "Opening %@"), connection.name),
                description: String(localized: "Your request is sent as soon as the connection is up.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.viewModel.messages) { message in
                        AIChatMessageView(message: message)
                            .equatable()
                            .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let failure {
            failureNotice(failure)
        } else {
            connectingNotice
        }
    }

    private func failureNotice(_ reason: ConnectionUnavailableReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                ConnectionUnavailablePresentation.headline(
                    reason: reason,
                    connectionName: connection.name
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .bold()
            ForEach(
                Array(ConnectionUnavailablePresentation.detailLines(reason: reason).enumerated()),
                id: \.offset
            ) { line in
                Text(line.element)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button(
                    ConnectionUnavailablePresentation.primaryActionTitle(reason: reason),
                    action: onRetry
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Cancel is an ordinary push button, not a link. A link style says the control navigates
    /// somewhere, and this one stops the connect the sentence beside it is describing.
    private var connectingNotice: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(format: String(localized: "Connecting to %@…"), connection.name))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Cancel"), action: onCancel)
                .controlSize(.small)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    /// The prompt is editable while the connection is being made, because a connect can take long
    /// enough to notice a typo in and a field that shows text it will not let you change is worse
    /// than no field. What is typed here is what `sendPendingPromptIfReady` sends, so there is
    /// nothing to submit to yet and `Return` inserts a newline like it would in any composer whose
    /// send is not available.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            /// Mentions stay closed here rather than being offered and left empty: `@` completes
            /// against tables and columns, which is a schema read this connection cannot answer
            /// yet. With no text change reported, nothing is ever proposed and `onAttach` is
            /// unreachable, so neither is a control that does nothing.
            ChatComposerView(
                text: pendingPromptBinding,
                placeholder: String(localized: "Ask about your database…"),
                minLines: 1,
                maxLines: 5,
                mentionState: mentionState,
                onTextChange: { _, _ in },
                onSubmit: {},
                onAttach: { _ in }
            )
            queuedNotice
        }
        .padding(8)
    }

    @ViewBuilder
    private var queuedNotice: some View {
        if let prompt = session.pendingPrompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            Label(
                String(localized: "Sends as soon as the connection is up."),
                systemImage: "clock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// `pendingPrompt` is optional because a session usually has none, and the composer wants a
    /// string. Empty text clears it rather than queuing a blank turn.
    private var pendingPromptBinding: Binding<String> {
        Binding(
            get: { session.pendingPrompt ?? "" },
            set: { text in
                session.pendingPrompt = text.isEmpty ? nil : text
            }
        )
    }
}
