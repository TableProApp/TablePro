//
//  AgentResultPaneView.swift
//  TablePro
//

import SwiftUI

/// What the session proposed, ran and changed, beside the conversation that produced it.
///
/// The pane exists so the floor can stay strict without a dialog per statement: a durable surface
/// the user can review out of band is what the products that shipped this pattern reached for after
/// per-call prompting turned into approval fatigue.
///
/// It holds reviewable output only. Intermediate working text belongs in the conversation; the one
/// shipped precedent for this column split scratch output out of it in one release and removed it
/// in the next.
internal struct AgentResultPaneView: View {
    @ObservedObject internal var session: AgentSession
    internal let connection: DatabaseConnection?

    @State private var segment: AgentResultSegment = .sql

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Icon-only segments with a name each. Four localized titles truncate in German and French at
    /// the trailing pane's 270pt minimum, which is exactly the width this sits at.
    private var picker: some View {
        Picker(String(localized: "Result view"), selection: $segment) {
            ForEach(AgentResultSegment.allCases, id: \.self) { item in
                Image(systemName: item.symbolName)
                    .help(item.title)
                    .accessibilityLabel(item.title)
                    .tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .sql:
            AgentProposedStatementsView(session: session)
        case .plan:
            emptyState(
                title: String(localized: "No steps yet"),
                description: String(localized: "What the session does will be listed here.")
            )
        case .results:
            AgentResultRowsView(session: session, connection: connection)
        case .schema:
            emptyState(
                title: String(localized: "No schema changes"),
                description: String(localized: "Columns, indexes and constraints a statement would add or remove appear here.")
            )
        }
    }

    private func emptyState(title: String, description: String) -> some View {
        UnavailableStateView(title, systemImage: segment.symbolName, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

internal enum AgentResultSegment: String, CaseIterable, Hashable {
    case sql
    case plan
    case results
    case schema

    internal var title: String {
        switch self {
        case .sql: String(localized: "SQL")
        case .plan: String(localized: "Plan")
        case .results: String(localized: "Results")
        case .schema: String(localized: "Schema")
        }
    }

    internal var symbolName: String {
        switch self {
        case .sql: "curlybraces"
        case .plan: "list.number"
        case .results: "tablecells"
        case .schema: "square.stack.3d.up"
        }
    }
}
