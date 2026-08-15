import SwiftUI

struct HistoryDetailPane: View {
    let entry: QueryHistoryEntry?
    let connectionLabel: HistoryConnectionLabel?

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
        .accessibilityIdentifier("query-history-detail")
    }

    private func detail(for entry: QueryHistoryEntry) -> some View {
        VStack(spacing: 0) {
            HighlightedSQLTextView(sql: entry.query, databaseType: entry.databaseType)
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
                row(String(localized: "Duration"), entry.hasMeasuredDuration ? entry.formattedExecutionTime : "–")
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

    private func actions(for entry: QueryHistoryEntry) -> some View {
        HStack {
            Button(String(localized: "Copy")) { onCopy(entry) }
                .controlSize(.small)
                .accessibilityIdentifier("query-history-copy")

            Spacer()

            Button(String(localized: "Run in New Tab")) { onRunInNewTab(entry) }
                .controlSize(.small)
                .accessibilityIdentifier("query-history-run-in-new-tab")

            Button(String(localized: "Load in Editor")) { onLoadInEditor(entry) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("query-history-load-in-editor")
        }
        .padding(10)
    }
}
