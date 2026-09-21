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
    internal let contentMode: ConnectionWorkspaceContentMode

    @State private var segment: AgentResultSegment = .sql

    var body: some View {
        VStack(spacing: 0) {
            TrailingPaneHeaderView(
                surface: .agentResult,
                contentMode: contentMode,
                paneState: nil
            ) { section in
                menuSection(section)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func menuSection(_ section: TrailingPaneMenuSection) -> some View {
        switch section {
        case .resultView:
            segmentPicker
        case .inspectorRendering, .jsonReading, .conversations, .clearRecents:
            EmptyView()
        }
    }

    /// In the pane header's menu, where every surface keeps its commands, so the column's top edge
    /// lines up with the inspector's and the assistant's. It used to be an icon-only segmented control
    /// that was the whole top of the pane, the one surface of three with no title.
    private var segmentPicker: some View {
        Picker(String(localized: "Result view"), selection: $segment) {
            ForEach(AgentResultSegment.allCases, id: \.self) { item in
                Label(item.title, systemImage: item.symbolName)
                    .tag(item)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
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
