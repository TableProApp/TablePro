//
//  AgentSessionRailView.swift
//  TablePro
//

import SwiftUI

/// The sessions this connection has open, in the window's leading column while Agent mode is on.
///
/// Selection selects and nothing else. A `List` moves its selection on a single click and on every
/// arrow key, so acting on the change means the highlight cannot be moved without opening a session
/// and focus cannot pass through the list at all. Opening is its own command, on a double click and
/// in the context menu.
internal struct AgentSessionRailView: View {
    internal let connectionId: UUID
    @ObservedObject internal var registry: AgentSessionRegistry
    internal let selectedSessionId: UUID?
    internal let onSelect: (UUID) -> Void
    internal let onNewSession: () -> Void
    internal let onCloseSession: (UUID) -> Void

    @State private var listSelection: UUID?

    private var sessions: [AgentSession] {
        registry.sessions(for: connectionId)
    }

    var body: some View {
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
        .onAppear { listSelection = selectedSessionId }
        .onChange(of: selectedSessionId) { listSelection = $0 }
    }

    private var list: some View {
        List(selection: $listSelection) {
            Section(String(localized: "Sessions")) {
                ForEach(sessions) { session in
                    AgentSessionRow(session: session)
                        .tag(session.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onSelect(session.id) }
                        .contextMenu {
                            Button(String(localized: "Open Session")) { onSelect(session.id) }
                            Divider()
                            Button(String(localized: "Close Session")) { onCloseSession(session.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The empty state offers the command rather than describing where its button is.
    private var emptyState: some View {
        UnavailableStateView {
            Label(String(localized: "No sessions yet"), systemImage: "sparkles")
        } description: {
            Text(String(localized: "Start one to ask about this connection."))
        } actions: {
            Button(String(localized: "New Session"), action: onNewSession)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A bordered button in a bottom bar, which is the shape a source list uses for adding to itself.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button(action: onNewSession) {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "New Session"))
            .accessibilityLabel(String(localized: "New Session"))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// One session, as a source-list row: what it is about, and what it is doing.
private struct AgentSessionRow: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.status.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
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
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(session.status.title)
    }

    private var title: String {
        session.title.isEmpty ? String(localized: "New Session") : session.title
    }
}
