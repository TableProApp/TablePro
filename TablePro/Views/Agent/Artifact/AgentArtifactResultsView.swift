//
//  AgentArtifactResultsView.swift
//  TablePro
//

import SwiftUI

/// What each query the session ran actually returned: the rows, the count, how long it took, and the
/// plan when the session asked for one.
///
/// This is the segment that separates the surface from a wider chat window. The model's sentence
/// about a result and the result are two different things, and only one of them came from the
/// database.
internal struct AgentArtifactResultsView: View {
    internal let runs: [QueryRun]
    internal let connectionId: UUID?

    internal var body: some View {
        List {
            ForEach(runs) { run in
                AgentArtifactRunRow(run: run, connectionId: connectionId)
            }
        }
        .listStyle(.inset)
    }
}

/// One run. The payload is decoded here rather than when the artifact was built, so a session with a
/// hundred results decodes only the handful of rows on screen.
private struct AgentArtifactRunRow: View {
    let run: QueryRun
    let connectionId: UUID?

    private var summary: QueryRunSummary? { QueryRunSummary.decode(run.resultJSON) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let summary {
                metrics(summary)
                let shown = Array(summary.rows.prefix(Self.previewRowLimit))
                if !summary.columns.isEmpty, !shown.isEmpty {
                    resultTable(columns: summary.columns, rows: shown)
                }
                if summary.rowCount > shown.count {
                    truncationNotice(summary, shown: shown.count)
                }
                if let statusMessage = summary.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "This result could not be read back."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            planSection
        }
        .padding(.vertical, 7)
        .contextMenu { CopySQLButton(sql: run.sql) }
    }

    private func metrics(_ summary: QueryRunSummary) -> some View {
        HStack(spacing: 12) {
            Label(
                String(format: String(localized: "%d rows"), summary.rowCount),
                systemImage: "tablecells"
            )
            if summary.rowsAffected > 0 {
                Label(
                    String(format: String(localized: "%d affected"), summary.rowsAffected),
                    systemImage: "pencil"
                )
            }
            if let duration = summary.durationMs {
                Label(
                    String(format: String(localized: "%.0f ms"), duration),
                    systemImage: "clock"
                )
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    /// `Grid`, which is a layout that aligns columns, rather than a stack of `HStack`s that only
    /// looks like one.
    ///
    /// The version this replaces gave every cell `minWidth: 60` and let it grow with its own
    /// content, so a column was only as wide as each cell independently decided and the columns did
    /// not line up between rows at all: one long value in row three shifted every value to its
    /// right, on that row alone. `Grid` sizes a column once from every cell in it, which is the
    /// whole reason it exists.
    ///
    /// `Table` would be better still, for the selection and the resizable headers it brings, but
    /// its columns have to be known at compile time and these are the result's own.
    /// `TableColumnForEach` lifts that and needs macOS 14.4; the app supports 14.0.
    /// A preview is a handful of rows, so the table renders a handful and says how many there are.
    ///
    /// It scrolls sideways only. A vertically scrolling view inside a `List` row fights the list for
    /// the same gesture, so a scroll begun over a result would be swallowed by the result instead of
    /// moving the pane; capping the rows removes the need for one. Every row is still on the
    /// clipboard and in a query tab through **Open as Query**.
    private static let previewRowLimit = 10

    private func resultTable(columns: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { column in
                        Text(column.element)
                            .font(.caption)
                            .bold()
                            .lineLimit(1)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    GridRow {
                        ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                            Text(cell.element)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .help(cell.element)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.rowLabel(columns: columns, cells: row.element))
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    /// A row read as "column: value", so VoiceOver says which column a value came from. The grid
    /// used to publish a flat run of `Text` in which a value carried no column at all.
    private static func rowLabel(columns: [String], cells: [String]) -> String {
        zip(columns, cells)
            .map { String(format: String(localized: "%1$@: %2$@"), $0.0, $0.1) }
            .joined(separator: ", ")
    }

    /// The pane shows a window onto a large result and says so, with the way to the whole thing
    /// alongside. Rendering every row here would put the result's layout cost in the same pass as the
    /// conversation's.
    private func truncationNotice(_ summary: QueryRunSummary, shown: Int) -> some View {
        HStack(spacing: 8) {
            Text(
                String(
                    format: String(localized: "Showing %1$d of %2$d rows."),
                    shown,
                    summary.rowCount
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let connectionId {
                Button(String(localized: "Open as Query")) {
                    WindowManager.shared.openTab(
                        payload: EditorTabPayload(
                            connectionId: connectionId,
                            tabType: .query,
                            initialQuery: run.sql,
                            forcesNewTab: true
                        )
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var planSection: some View {
        if let planText = run.planText {
            DisclosureGroup(String(localized: "Query plan")) {
                Text(planText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }
}
