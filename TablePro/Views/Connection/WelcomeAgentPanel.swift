//
//  WelcomeAgentPanel.swift
//  TablePro
//

import SwiftUI

/// The welcome window's second way in: describe the job and land in Assistant mode, without opening
/// the object browser first.
///
/// A per-connection action, not an app mode. **Browse database** is still what `Return` and a double
/// click do in the list, so nothing about the existing way in changes; this is a second action on the
/// connection already selected.
///
/// Sessions already running or stopped are listed underneath, which is where a session that outlived
/// its window becomes reachable. Read straight from the registry rather than folded into the
/// connection tree: `treeItems` is rebuilt from `connections` on every mutation, and a session list
/// inside it would be rebuilt with it and would have to be kept in step by hand.
internal struct WelcomeAgentPanel: View {
    internal let registry: AgentSessionRegistry
    internal let selectedConnection: DatabaseConnection?
    internal let onBrowse: (DatabaseConnection) -> Void
    internal let onAsk: (DatabaseConnection, String) -> Void
    internal let onOpenSession: (AgentSession) -> Void

    @State private var prompt: String = ""
    @FocusState private var promptFocused: Bool

    private var sessions: [AgentSession] {
        registry.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    internal var body: some View {
        VStack(spacing: 0) {
            if !sessions.isEmpty {
                Divider()
                sessionList
            }
            if let selectedConnection {
                Divider()
                composer(selectedConnection)
            }
        }
        .background(.bar)
    }

    private func composer(_ connection: DatabaseConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ConnectionTypeIcon(type: connection.type)
                    .frame(width: 14, height: 14)
                Text(connection.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                /// A command, so a button. `.link` styles a control that navigates to content, and
                /// this one opens the object browser on the connection already selected.
                Button(String(localized: "Browse database")) {
                    onBrowse(connection)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            /// An ordinary push button, not a bare glyph. `.plain` on an `Image` gives a control
            /// with no border, no press state, no focus ring and no name of its own, which is a
            /// custom button drawn to look like the one iMessage has; the send here is a command in
            /// a form and reads as one.
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    String(localized: "Ask the assistant"),
                    text: $prompt,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($promptFocused)
                .onSubmit { ask(connection) }

                Button(String(localized: "Ask")) {
                    ask(connection)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedPrompt.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Sessions"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            /// A `List`, not a `ScrollView` of `.plain` buttons. The hand-rolled version had no
            /// selection, no hover, no keyboard navigation and no row semantics for VoiceOver, and a
            /// list of things you open is exactly what a list is for. `.onKeyPress` is not needed:
            /// a `List` selection already answers arrow keys, and `Return` opens through
            /// `onOpenSession`.
            List(sessions, selection: openBinding) { session in
                HStack(spacing: 6) {
                    Image(systemName: session.status.icon)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(session.displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.status.localizedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .tag(session.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(
                        format: String(localized: "%1$@, %2$@"),
                        session.displayTitle,
                        session.status.localizedTitle
                    )
                )
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 132)
        }
    }

    /// Selecting a row is what opens it, so the binding never holds a value: it takes the id,
    /// opens, and reports nothing selected. A stored selection would light a row in a panel whose
    /// window is about to close.
    private var openBinding: Binding<UUID?> {
        Binding(
            get: { nil },
            set: { id in
                guard let id, let session = sessions.first(where: { $0.id == id }) else { return }
                onOpenSession(session)
            }
        )
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The field is cleared before the launch is dispatched. The window closes as the connection
    /// opens, and text left behind would come back the next time the welcome window appeared.
    private func ask(_ connection: DatabaseConnection) {
        let text = trimmedPrompt
        guard !text.isEmpty else { return }
        prompt = ""
        promptFocused = false
        onAsk(connection, text)
    }
}
