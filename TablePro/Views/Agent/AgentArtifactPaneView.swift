//
//  AgentArtifactPaneView.swift
//  TablePro
//

import SwiftUI

/// What the session produced, in the inspector's column: the SQL it proposes, the steps it took,
/// the rows it got back, and the schema change a DDL statement would make.
///
/// This is what separates the surface from a wider chat window: the user checks the database's own
/// answer instead of the model's sentence about it.
internal enum AgentArtifactSegment: String, CaseIterable, Identifiable {
    case sql
    case plan
    case results
    case schema

    internal var id: String { rawValue }

    internal var localizedTitle: String {
        switch self {
        case .sql: return String(localized: "SQL")
        case .plan: return String(localized: "Plan")
        case .results: return String(localized: "Results")
        case .schema: return String(localized: "Schema")
        }
    }

    internal var icon: String {
        switch self {
        case .sql: return "curlybraces"
        case .plan: return "list.bullet.indent"
        case .results: return "tablecells"
        case .schema: return "square.stack.3d.up"
        }
    }

    internal var emptyTitle: String {
        switch self {
        case .sql: return String(localized: "No statements yet")
        case .plan: return String(localized: "No steps yet")
        case .results: return String(localized: "No results yet")
        case .schema: return String(localized: "No schema changes")
        }
    }

    internal var emptyDescription: String {
        switch self {
        case .sql:
            return String(localized: "SQL the assistant proposes appears here, with Run and Reject on each statement.")
        case .plan:
            return String(localized: "The steps the assistant has taken appear here as it works.")
        case .results:
            return String(localized: "Rows, count, duration and the query plan appear here after a query runs.")
        case .schema:
            return String(localized: "Columns, indexes and constraints a statement would add or remove appear here.")
        }
    }
}

internal struct AgentArtifactPaneView: View {
    /// Nil before the connection is up. The pane still renders its empty states then; only the
    /// Safe Mode notice needs a connection to speak about.
    internal let connectionId: UUID?

    /// Nil before there is a session. Every segment reads its content from the session's transcript,
    /// so a pane with no session is the same as a pane with an empty one.
    internal let session: AgentSession?

    /// The chosen segment lives on the session, which outlives this view. Held here only for the
    /// sessionless pane, which has nowhere else to put it and nothing to show in any case.
    @State private var sessionlessSegment: AgentArtifactSegment = .sql

    internal init(connectionId: UUID? = nil, session: AgentSession? = nil) {
        self.connectionId = connectionId
        self.session = session
    }

    private var segment: Binding<AgentArtifactSegment> {
        guard let session else { return $sessionlessSegment }
        return Binding(get: { session.artifactSegment }, set: { session.artifactSegment = $0 })
    }

    /// Recomputed from the transcript on every pass rather than cached beside it.
    ///
    /// The projection reads `messages` and each block's approval state, both observed, so this
    /// invalidates exactly when the session changes and can never disagree with the conversation.
    /// A stored copy would need its own invalidation and would be wrong after a restore, when the
    /// transcript arrives without any of the stream events that built it.
    private var artifact: AgentArtifact {
        guard let session else { return AgentArtifact() }
        return AgentArtifactProjection.build(
            from: session.viewModel.messages,
            connectionName: session.connectionName,
            databaseType: session.viewModel.connection?.type ?? .mysql
        )
    }

    /// The floor notice sits under the content, not between the picker and it.
    ///
    /// It appears and disappears with the mode, and above the divider that made the whole pane jump
    /// by its height each time. A `safeAreaInset` puts it in the pane's own bottom bar, which is
    /// where a standing condition belongs and where its arrival scrolls the list rather than moving
    /// the picker the reader is aiming at.
    internal var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { floorBar }
    }

    /// The bar exists only when there is a notice to put in it.
    ///
    /// `AssistantFloorNoticeView` draws nothing when the floor is off, so framing it unconditionally
    /// would leave a divider and an empty padded strip along the bottom of the pane. That the two
    /// conditions happen to agree today, because the pane is only shown in assistant mode and the
    /// floor is on in assistant mode, is a coincidence between two types rather than a guarantee.
    @ViewBuilder
    private var floorBar: some View {
        if let connectionId, AssistantSafeModeFloor.isActive(for: connectionId) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    AssistantFloorNoticeView(connectionId: connectionId)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }

    /// Every arm resolves to a view, including the ones that cannot happen. A `@ViewBuilder` branch
    /// with no `else` renders nothing at all, and the SQL arm had one: a statement with no session
    /// is unreachable today only because the projection is empty without one, which is a fact about
    /// another type rather than a guarantee this view can rely on.
    @ViewBuilder
    private var content: some View {
        let artifact = artifact
        switch segment.wrappedValue {
        case .sql:
            if let session, !artifact.statements.isEmpty {
                AgentArtifactSQLView(statements: artifact.statements, sessionId: session.id)
            } else {
                emptyState
            }
        case .plan:
            if artifact.steps.isEmpty {
                emptyState
            } else {
                AgentArtifactPlanView(steps: artifact.steps)
            }
        case .results:
            if artifact.runs.isEmpty {
                emptyState
            } else {
                AgentArtifactResultsView(runs: artifact.runs, connectionId: connectionId)
            }
        case .schema:
            if artifact.schemaChanges.isEmpty {
                emptyState
            } else {
                AgentArtifactSchemaView(changes: artifact.schemaChanges)
            }
        }
    }

    private var emptyState: some View {
        let segment = segment.wrappedValue
        return EmptyStateView(
            icon: segment.icon,
            title: segment.emptyTitle,
            description: segment.emptyDescription
        )
    }

    /// The label is real and then hidden, rather than empty with an accessibility label bolted on:
    /// a `Picker` takes its accessibility name from its own label, so naming it once is what makes
    /// the visible layout and VoiceOver agree without a second string to keep in step.
    private var picker: some View {
        Picker(String(localized: "Artifact"), selection: segment) {
            ForEach(AgentArtifactSegment.allCases) { candidate in
                Text(candidate.localizedTitle).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
