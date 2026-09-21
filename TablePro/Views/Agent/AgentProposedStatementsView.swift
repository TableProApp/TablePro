//
//  AgentProposedStatementsView.swift
//  TablePro
//

import SwiftUI

/// Every statement the session proposed, in order, with what became of it.
///
/// Handed the statements rather than the session, because projecting them out of the transcript is
/// what `AgentArtifactCache` does once per change instead of once per redraw.
internal struct AgentProposedStatementsView: View {
    internal let statements: [ProposedStatement]

    var body: some View {
        if statements.isEmpty {
            UnavailableStateView(
                String(localized: "No Statements Yet"),
                systemImage: "curlybraces",
                description: Text(String(localized: "SQL the session proposes appears here before it runs."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(statements) { statement in
                row(statement)
                    .contextMenu {
                        Button(String(localized: "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(statement.sql, forType: .string)
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    /// Statement at the data-grid value font, metadata at `.caption`, matching the app's other list
    /// of statements with state under them. A stored value drawn at a system text style is the
    /// two-font-domain defect: it looks right only until the user changes one of the two settings.
    private func row(_ statement: ProposedStatement) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(statement.sql)
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 4) {
                Image(systemName: statement.state.symbolName)
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(statement.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statement.sql)
        .accessibilityValue(statement.state.title)
    }
}
