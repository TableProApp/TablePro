//
//  AgentArtifactSQLView.swift
//  TablePro
//

import SwiftUI

/// Every statement the session proposed, in order, with its state and, while it waits, **Run** and
/// **Reject**.
///
/// No "Always for this connection". A grant made here would name one statement and mean every write
/// on the connection, and the whole point of this list is that each statement is read on its own.
/// The button in the conversation card is unchanged and stays the only place a grant is offered.
///
/// Type and rhythm follow `QueryInsightsGroupList`, which is the app's other list of statements
/// with metadata beneath them: statements at `.callout` monospaced, metadata at `.caption`, three
/// points between the lines of a row and seven above and below it. This pane used to set every one
/// of those a step smaller, so the same statement read as a footnote here and as content there.
internal struct AgentArtifactSQLView: View {
    internal let statements: [ProposedStatement]
    internal let sessionId: UUID

    internal var body: some View {
        List {
            ForEach(statements) { statement in
                row(statement)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ statement: ProposedStatement) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header(statement)

            Text(statement.sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if statement.awaitsDecision {
                Text(String(format: String(localized: "Targets %@"), statement.connectionName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                decisionButtons(statement)
            } else if let detail = statement.state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 7)
        .contextMenu { CopySQLButton(sql: statement.sql) }
    }

    /// The state's icon carries the state's name, so VoiceOver reads "Waiting" rather than skipping
    /// a decorative image and leaving the row's status unsaid.
    private func header(_ statement: ProposedStatement) -> some View {
        HStack(spacing: 6) {
            Image(systemName: statement.state.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statement.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(statement.state.localizedTitle)
                .font(.caption)
                .bold()
            if statement.isDestructive {
                StatusBadge(String(localized: "Destructive"), tint: .destructive)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func decisionButtons(_ statement: ProposedStatement) -> some View {
        HStack(spacing: 8) {
            Button(String(localized: "Run")) {
                resolve(statement, decision: .run)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(String(localized: "Reject")) {
                resolve(statement, decision: .cancel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(.top, 2)
    }

    private func resolve(_ statement: ProposedStatement, decision: ToolApprovalDecision) {
        ToolApprovalCenter.shared.resolve(
            ApprovalRequestID(sessionId: sessionId, toolUseId: statement.id),
            decision: decision
        )
    }
}

/// Copy on a statement, which the pane had no way to offer.
///
/// `textSelection(.enabled)` lets a reader drag across the text and press Copy, which is not the
/// same thing: it needs a precise drag over a block that may be eight lines long and truncated, and
/// a right-click on it did nothing at all.
internal struct CopySQLButton: View {
    internal let sql: String

    internal var body: some View {
        Button(String(localized: "Copy")) {
            ClipboardService.shared.writeText(sql)
        }
    }
}
