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

    /// One per window, not per session: the column is a hosting controller that outlives every
    /// session switch, which is why what the cache holds is named by the session it came from.
    @StateObject private var artifacts = AgentArtifactCache()

    var body: some View {
        let artifact = artifacts.artifact(for: session)
        VStack(spacing: 0) {
            TrailingPaneHeaderView(
                surface: .agentResult,
                contentMode: contentMode,
                paneState: nil
            ) { section in
                menuSection(section)
            }
            content(artifact)
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
    ///
    /// The choice is the session's, so a switch between two sessions no longer hands one of them the
    /// other's view.
    private var segmentPicker: some View {
        Picker(String(localized: "Result view"), selection: $session.resultSegment) {
            ForEach(AgentResultSegment.allCases, id: \.self) { item in
                Label(item.title, systemImage: item.symbolName)
                    .tag(item)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    @ViewBuilder
    private func content(_ artifact: AgentArtifact) -> some View {
        switch session.resultSegment {
        case .sql:
            AgentProposedStatementsView(statements: artifact.statements)
        case .results:
            AgentResultRowsView(runs: artifact.runs, artifacts: artifacts, connection: connection)
        }
    }
}
