import SwiftUI
import TableProPluginKit

struct HistoryDetailPane: View {
    let entry: QueryHistoryEntry?
    let connectionLabel: HistoryConnectionLabel?
    let canRunInNewTab: Bool

    let onLoadInEditor: (QueryHistoryEntry) -> Void
    let onRunInNewTab: (QueryHistoryEntry) -> Void
    let onCopy: (QueryHistoryEntry) -> Void

    var body: some View {
        Group {
            if let entry {
                detail(for: entry)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Query Selected"), systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Select a query to see its full text and details.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query-history-detail")
    }

    /// The preview is named on the `NSTextView` itself rather than through a SwiftUI modifier, which
    /// is both because a modifier cannot reach the view behind an `NSViewRepresentable` and because
    /// the identifier on the enclosing container would overwrite a SwiftUI one.
    private func detail(for entry: QueryHistoryEntry) -> some View {
        VStack(spacing: 0) {
            HighlightedSQLTextView(
                sql: entry.query,
                databaseType: entry.databaseType,
                accessibilityIdentifier: "query-history-detail-query"
            )
            .background(Color(nsColor: ThemeEngine.shared.colors.editor.background))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            metadata(for: entry)

            Divider()

            actions(for: entry)
        }
    }

    private func metadata(for entry: QueryHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let connectionLabel {
                    row(String(localized: "Connection"), connectionLabel.name)
                }
                row(String(localized: "Database"), databaseDescription(for: entry))
                row(String(localized: "Ran"), entry.executedAt.formatted(date: .abbreviated, time: .standard))
                durationRows(for: entry)
                row(String(localized: "Rows"), entry.hasKnownRowCount ? entry.formattedRowCount : "–")
                row(String(localized: "Source"), entry.source.displayName)
            }

            if let errorMessage = entry.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A driver that could separate execution from transfer gets every part it measured, because
    /// the whole point of storing them is that the elapsed number alone does not say which was slow.
    @ViewBuilder
    private func durationRows(for entry: QueryHistoryEntry) -> some View {
        if !entry.hasMeasuredDuration {
            row(String(localized: "Duration"), "–")
        } else if entry.timing.hasBreakdown {
            ForEach(QueryTimingBreakdown(timing: entry.timing).rows) { breakdownRow in
                row(breakdownRow.label, breakdownRow.value)
            }
        } else {
            row(String(localized: "Duration"), entry.formattedExecutionTime)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func databaseDescription(for entry: QueryHistoryEntry) -> String {
        guard let schemaName = entry.schemaName, !schemaName.isEmpty else { return entry.databaseDisplayName }
        return "\(entry.databaseDisplayName).\(schemaName)"
    }

    /// Return already belongs to the list, which activates the row the user is standing on. This is
    /// a persistent pane rather than a dialog, so the primary action is marked by prominence alone
    /// and never takes the window's default action, which would fire on any responder that ignores
    /// Return.
    private func actions(for entry: QueryHistoryEntry) -> some View {
        HStack {
            Button(String(localized: "Copy")) { onCopy(entry) }
                .controlSize(.small)
                .accessibilityIdentifier("query-history-copy")

            Spacer()

            Button(String(localized: "Run in New Tab")) { onRunInNewTab(entry) }
                .controlSize(.small)
                .disabled(!canRunInNewTab)
                .help(canRunInNewTab
                    ? String(localized: "Open this query in a new tab and run it")
                    : String(localized: "This query belongs to another connection. Load it in the editor to run it there."))
                .accessibilityIdentifier("query-history-run-in-new-tab")

            Button(String(localized: "Load in Editor")) { onLoadInEditor(entry) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("query-history-load-in-editor")
        }
        .padding(10)
    }
}
