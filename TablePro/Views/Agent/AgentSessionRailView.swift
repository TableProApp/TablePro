//
//  AgentSessionRailView.swift
//  TablePro
//

import SwiftUI

/// The sidebar's content in assistant mode: every session the app is holding, in place of the
/// object browser.
///
/// Sessions on the connection this window is showing come first, because that is the set the user
/// is working in; the rest are listed under their own connection's name so a session that outlived
/// its window is reachable rather than merely remembered.
internal struct AgentSessionRailView: View {
    internal let registry: AgentSessionRegistry
    internal let currentConnectionId: UUID?
    internal let selectedSessionId: UUID?
    internal let onSelect: (UUID) -> Void
    internal let onNewSession: (() -> Void)?
    internal let onRemove: (UUID) -> Void

    private var currentSessions: [AgentSession] {
        guard let currentConnectionId else { return [] }
        return registry.sessions(for: currentConnectionId).sorted { $0.createdAt < $1.createdAt }
    }

    private var otherSessions: [AgentSession] {
        registry.sessions
            .filter { $0.connectionId != currentConnectionId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    internal var body: some View {
        content
            .safeAreaInset(edge: .bottom) { newSessionBar }
    }

    /// The empty state offers the action rather than describing where to find it, which is what
    /// `ContentUnavailableView` is shaped for and what the rest of the app's empty states do. It
    /// used to read "Ask a question below", and there is no composer below the rail.
    @ViewBuilder
    private var content: some View {
        if registry.sessions.isEmpty {
            EmptyStateView(
                icon: "sparkles",
                title: String(localized: "No session yet"),
                description: String(localized: "Start one to ask the assistant about this connection."),
                actionTitle: onNewSession == nil ? nil : String(localized: "New Session"),
                actionSystemImage: onNewSession == nil ? nil : "plus",
                action: onNewSession
            )
        } else {
            List(selection: selectionBinding) {
                if !currentSessions.isEmpty {
                    Section(String(localized: "This Connection")) {
                        ForEach(currentSessions) { session in
                            row(session)
                        }
                    }
                }
                if !otherSessions.isEmpty {
                    Section(String(localized: "Other Connections")) {
                        ForEach(otherSessions) { session in
                            row(session)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// A `List` selection writes through this rather than owning the value, so the rail always shows
    /// what the window is actually rendering. A rail with its own `@State` would keep a stale row
    /// lit after the window switched connection.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { selectedSessionId },
            set: { next in
                guard let next else { return }
                onSelect(next)
            }
        )
    }

    private func row(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.status.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .lineLimit(1)
                Text(statusLine(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .tag(session.id)
        .contextMenu {
            Button(String(localized: "Close Session"), role: .destructive) {
                onRemove(session.id)
            }
        }
        /// Combined first, then named. Without the combine the row publishes three children and the
        /// label lands on the container, so VoiceOver reads the title and the status twice: once as
        /// the row's name and again as it walks into it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: String(localized: "%1$@, %2$@"),
                session.displayTitle,
                statusLine(session)
            )
        )
    }

    /// Every row names its connection, including the ones on the connection on screen: two sessions
    /// on one connection are told apart by their titles, and a title taken from a first message says
    /// nothing about which database it ran against.
    private func statusLine(_ session: AgentSession) -> String {
        let status = session.statusDetail ?? session.status.localizedTitle
        return String(format: String(localized: "%1$@ · %2$@"), session.connectionName, status)
    }

    /// The bottom bar a source list carries its add affordance in, which is where the system puts
    /// one: a small borderless `+` at the leading edge rather than a full-width row.
    ///
    /// It was a `.plain` button spanning the bar, which is a custom row wearing a button's name: no
    /// press state, no hover, no focus ring, and a hit area covering the whole width of a control
    /// whose meaning is a single glyph. `.borderless` is the style the system's own source lists
    /// use here, and it brings all four back.
    @ViewBuilder
    private var newSessionBar: some View {
        if let onNewSession {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    Button(action: onNewSession) {
                        Label(String(localized: "New Session"), systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(String(localized: "New Session"))
                    .accessibilityLabel(String(localized: "New Session"))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}
