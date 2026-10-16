//
//  AgentProposedStatementsView.swift
//  TablePro
//

import SwiftUI
import TableProTheme

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
                AgentProposedStatementRow(statement: statement)
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
}

/// Statement at the data-grid value font, metadata at `.caption`: a stored value drawn at a system
/// text style looks right only until the user changes one of the two font settings.
internal struct AgentProposedStatementRow: View {
    /// `ProposedStatement` is equatable, so without this the row would skip a font change.
    @ObservedObject private var themeEngine = ThemeEngine.shared

    internal let statement: ProposedStatement

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(statement.sql)
                .font(themeEngine.valueFontSwiftUI)
                // The list has no selection, so a theme color here never sits on a selected-row fill.
                .themeForeground(.editorText, native: .primary)
                .lineLimit(4)
                .textSelection(.enabled)
                .modifier(ProposedStatementWell())
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

/// The well a chat `CodeWell` draws, shown only while the theme sets the editor background, so under a
/// theme that leaves it alone the row draws what it always has. One chain rather than a branch, so a
/// theme switch keeps the text and its selection.
private struct ProposedStatementWell: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    private static let shape = RoundedRectangle(cornerRadius: 6)

    func body(content: Content) -> some View {
        let background = ThemeShapeStyle.override(.editorBackground, engine: themeEngine, contrast: contrast)
        return content
            .padding(background == nil ? 0 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background ?? .clear, in: Self.shape)
            .overlay(Self.shape.stroke(background == nil ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
