//
//  QueryRunPages.swift
//  TablePro
//

import SwiftUI

/// The Message or Summary page of a query tab's results pane.
struct QueryRunPage: View {
    let page: ResultsPage
    let display: TabDisplayState
    let onShowResult: (UUID) -> Void

    var body: some View {
        Group {
            if page == .summary {
                QueryRunSummaryView(
                    log: display.runLog,
                    openableResultIds: Set(display.resultSets.map(\.id)),
                    onShowResult: onShowResult
                )
            } else {
                QueryRunMessageView(log: display.runLog)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Message tab: the last run as selectable monospaced text, one block per statement.
struct QueryRunMessageView: View {
    let log: QueryRunLog?

    var body: some View {
        if let log {
            ServerOutputTextView(
                text: log.messageText,
                accessibilityLabel: String(localized: "Messages"),
                accessibilityIdentifier: "query-run-messages"
            )
        } else {
            QueryRunEmptyView()
        }
    }
}

/// The Summary tab: one row per statement of the last run. Double-clicking a row whose statement produced a result
/// still on the tab opens that result.
struct QueryRunSummaryView: View {
    let log: QueryRunLog?
    /// The results still on the tab, so a row whose result was closed does not offer to open it.
    let openableResultIds: Set<UUID>
    let onShowResult: (UUID) -> Void

    @State private var selection: Set<QueryRunLogEntry.ID> = []

    private static let numberTitle = "#"

    var body: some View {
        if let log {
            table(log)
        } else {
            QueryRunEmptyView()
        }
    }

    private func table(_ log: QueryRunLog) -> some View {
        Table(log.entries, selection: $selection) {
            TableColumn(Self.numberTitle) { entry in
                Text(entry.ordinal, format: .number)
                    .monospacedDigit()
            }
            .width(min: 24, ideal: 32, max: 56)

            TableColumn(String(localized: "Query")) { entry in
                Text(QueryRunLog.displayStatement(entry.statement))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.statement)
            }
            .width(min: 120, ideal: 360)

            TableColumn(String(localized: "Status")) { entry in
                statusLabel(entry.outcome)
            }
            .width(min: 64, ideal: 88, max: 140)

            TableColumn(String(localized: "Rows")) { entry in
                Text(QueryRunLog.rowCount(for: entry.outcome).map { String($0) } ?? "")
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 72, max: 120)

            TableColumn(String(localized: "Time")) { entry in
                Text(entry.executionTime.map(QueryRunLog.timeText) ?? "")
                    .monospacedDigit()
            }
            .width(min: 48, ideal: 72, max: 120)
        }
        .contextMenu(forSelectionType: QueryRunLogEntry.ID.self) { ordinals in
            Button(String(localized: "Show Result")) {
                if let id = openableResult(in: log, among: ordinals) { onShowResult(id) }
            }
            .disabled(openableResult(in: log, among: ordinals) == nil)
            Button(String(localized: "Copy Statement")) {
                copyStatements(in: log, among: ordinals)
            }
            .disabled(ordinals.isEmpty)
        } primaryAction: { ordinals in
            if let id = openableResult(in: log, among: ordinals) { onShowResult(id) }
        }
        .accessibilityIdentifier("query-run-summary")
    }

    private func statusLabel(_ outcome: QueryStatementOutcome) -> some View {
        HStack(spacing: 4) {
            switch outcome {
            case .returnedRows, .affectedRows, .plan:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
            }
            Text(QueryRunLog.statusText(for: outcome))
        }
        .help(Self.statusHelp(outcome))
    }

    private static func statusHelp(_ outcome: QueryStatementOutcome) -> String {
        guard case .failed(let message) = outcome else { return QueryRunLog.statusText(for: outcome) }
        return message
    }

    // Of the rows acted on, the first whose result is still on the tab.
    private func openableResult(in log: QueryRunLog, among ordinals: Set<QueryRunLogEntry.ID>) -> UUID? {
        log.entries
            .filter { ordinals.contains($0.ordinal) }
            .compactMap(\.resultSetId)
            .first { openableResultIds.contains($0) }
    }

    private func copyStatements(in log: QueryRunLog, among ordinals: Set<QueryRunLogEntry.ID>) {
        let statements = log.entries.filter { ordinals.contains($0.ordinal) }.map(\.statement)
        guard !statements.isEmpty else { return }
        ClipboardService.shared.writeText(statements.joined(separator: "\n"))
    }
}

private struct QueryRunEmptyView: View {
    var body: some View {
        UnavailableStateView(
            String(localized: "No Run Yet"),
            systemImage: "text.alignleft",
            description: Text(String(localized: "Run a query to see what each statement did."))
        )
    }
}
