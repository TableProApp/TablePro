//
//  AgentSessionRailView.swift
//  TablePro
//

import SwiftUI

/// The sessions this connection has open, in the window's leading column while Agent mode is on.
///
/// Selection selects and nothing else. A `List` moves its selection on a single click and on every
/// arrow key, so acting on the change means the highlight cannot be moved without opening a session
/// and focus cannot pass through the list at all. Opening is its own command, and it has four routes:
/// a double-click, Return on the highlighted row, the row's own Open Session action, and the context
/// menu. The first two are the list's primary action, which is `NSTableView`'s `doubleAction`
/// underneath and costs a single click nothing; the third is what makes the command reachable by
/// VoiceOver, Switch Control and Voice Control, which a double-click alone never was.
///
/// Never a `TapGesture(count: 2)` on the row: SwiftUI arbitrates that against the single tap by
/// holding every selection for the whole double-click interval, measured at 371ms.
internal struct AgentSessionRailView: View {
    internal let connectionId: UUID
    @ObservedObject internal var registry: AgentSessionRegistry
    @ObservedObject internal var railState: AgentSessionRailState
    /// The session the window is drawing, which the rail marks and follows with its highlight.
    internal let openSessionId: UUID?
    internal let onOpen: (UUID) -> Void
    internal let onNewSession: () -> Void
    internal let onClose: (UUID) -> Void
    internal let onDelete: (UUID) -> Void

    private var sessions: [AgentSession] {
        registry.sessions(for: connectionId)
    }

    private var highlightedSession: AgentSession? {
        guard let id = railState.highlightedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if sessions.isEmpty {
                    emptyState
                } else {
                    list
                }
                Divider()
                bottomBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { railState.highlightedSessionId = openSessionId }
            /// Opening a session, starting one and closing the one on screen all move which session
            /// the window draws, and the rail follows it: the new row is highlighted and scrolled to,
            /// which for a session just started is the top of the list.
            .onChange(of: openSessionId) { id in
                railState.highlightedSessionId = id
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var list: some View {
        List(selection: $railState.highlightedSessionId) {
            Section(String(localized: "Sessions")) {
                ForEach(sessions) { session in
                    AgentSessionRow(session: session, isOpen: session.id == openSessionId)
                        .tag(session.id)
                        .id(session.id)
                        .accessibilityAction(named: Text(String(localized: "Open Session"))) {
                            onOpen(session.id)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            onOpen(id)
        }
        /// The keyboard's half of the bottom bar's minus button, and the same confirmation.
        .onDeleteCommand {
            guard let session = highlightedSession else { return }
            onDelete(session.id)
        }
    }

    /// A contextual menu leaves out what does not apply rather than dimming it, which is the reverse
    /// of the menu bar's rule: Close Session is absent on a session that has already ended.
    ///
    /// The ids are the row under the pointer rather than the highlighted one. Measured on macOS 27:
    /// right-clicking the fourth row with the first one highlighted calls this with the fourth row's
    /// id alone, and leaves the highlight where it was.
    @ViewBuilder
    private func rowMenu(for ids: Set<UUID>) -> some View {
        if let id = ids.first, let session = sessions.first(where: { $0.id == id }) {
            Button(String(localized: "Open Session")) { onOpen(id) }
            if !session.status.isEnded {
                Button(String(localized: "Close Session")) { onClose(id) }
            }
            Divider()
            Button(String(localized: "Delete Session…")) { onDelete(id) }
        }
    }

    /// The empty state offers the command rather than describing where its button is.
    private var emptyState: some View {
        UnavailableStateView {
            Label(String(localized: "No Sessions Yet"), systemImage: "sparkles")
        } description: {
            Text(String(localized: "Start one to ask about this connection."))
        } actions: {
            Button(String(localized: "New Session"), action: onNewSession)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Add and remove at the foot of the list, which is the shape a source list keeps its own
    /// commands in. Removing is destructive and asks first, which the window does rather than the
    /// rail, so the menu bar's Delete Session asks the same question.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button(action: onNewSession) {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .help(String(localized: "New Session"))
            .accessibilityLabel(String(localized: "New Session"))
            .accessibilityIdentifier("agent-session-add")
            Button {
                guard let session = highlightedSession else { return }
                onDelete(session.id)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 20, height: 20)
            }
            .disabled(highlightedSession == nil)
            .help(String(localized: "Delete Session"))
            .accessibilityLabel(String(localized: "Delete Session"))
            .accessibilityIdentifier("agent-session-remove")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// One session, as a source-list row: what it is about, what it is doing, and whether it is the one
/// the window is drawing.
private struct AgentSessionRow: View {
    @ObservedObject var session: AgentSession
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.status.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                /// The status on its own line rather than joined to the title by a separator, which
                /// reads as generated and does not wrap.
                Text(session.status.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            /// The session on screen is marked the way a menu marks the item in force, since the
            /// highlight cannot say it: the highlight moves with every arrow key and opening is a
            /// command of its own.
            if isOpen {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.displayTitle)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard isOpen else { return session.status.title }
        return String(format: String(localized: "%@, open in this window"), session.status.title)
    }
}
