//
//  AgentResultRowsView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// The rows a session read, drawn by the app's own data grid.
///
/// Read-only, and modelled on `CompareRowGrid`, which is the other place a grid reviews rows it does
/// not own: a change manager of its own and a column layout held in `@State` so nothing reaches
/// `FileColumnLayoutPersister`. A `DataGridConfiguration` naming only the database type keeps
/// `columnLayoutKey` nil, so an agent result can never write into a real table's saved column
/// widths.
///
/// Sorting is answered here rather than announced and dropped. The rows are held in full and there
/// is no query to re-run, so `TableRowsSorting` puts them in order and the grid redraws; a grid
/// whose headers move a sort indicator that changes nothing is worse than one that cannot sort.
///
/// Drawing rows by hand here was the alternative and it is worse in ways that are not obvious: the
/// grid already gives type-aware formatting, the Data Grid font (rather than a system text style,
/// which is the two-font-domain defect), column separators that scale, an accessibility cell tree,
/// selection and copy. None of that is worth reimplementing beside the real one.
internal struct AgentResultRowsView: View {
    internal let runs: [AgentQueryRun]
    /// Decodes each run once. The pane owns it, so the answer survives a redraw and a sort.
    internal let artifacts: AgentArtifactCache
    internal let connection: DatabaseConnection?

    @State private var changeManager = AnyChangeManager(DataChangeManager())
    @State private var selectedRows: Set<Int> = []
    @State private var columnLayout = ColumnLayoutState()
    @State private var selectedRunId: String?
    @State private var sortState = SortState()
    @StateObject private var gridDelegate = AgentResultGridDelegate()

    var body: some View {
        if runs.isEmpty {
            UnavailableStateView(
                String(localized: "No Results Yet"),
                systemImage: "tablecells",
                description: Text(String(localized: "Rows the session reads appear here."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let run = runs.first { $0.id == selectedRunId } ?? runs[runs.count - 1]
            VStack(spacing: 0) {
                runPicker(runs: runs, current: run)
                Divider()
                result(for: run)
            }
            .onChange(of: run.id) { _ in
                selectedRows = []
                sortState = SortState()
            }
        }
    }

    private func runPicker(runs: [AgentQueryRun], current: AgentQueryRun) -> some View {
        Picker(String(localized: "Query"), selection: runBinding(runs: runs, current: current)) {
            ForEach(runs) { run in
                Text(summary(of: run.sql)).tag(run.id)
            }
        }
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func runBinding(runs: [AgentQueryRun], current: AgentQueryRun) -> Binding<String> {
        Binding(
            get: { current.id },
            set: { selectedRunId = $0 }
        )
    }

    /// Four answers where there used to be two, because "nothing to draw" was four different things
    /// and the pane said the same sentence for each: a write that changed rows read as a query that
    /// had matched none.
    @ViewBuilder
    private func result(for run: AgentQueryRun) -> some View {
        switch artifacts.payload(for: run) {
        case .rows(let decoded):
            grid(decoded, for: run)
        case .noRows:
            state(
                title: String(localized: "No Rows"),
                systemImage: "tablecells",
                description: String(localized: "The query returned no rows.")
            )
        case .completed(let rowsAffected):
            state(
                title: String(localized: "Statement Completed"),
                systemImage: "checkmark.circle",
                description: Self.changeSummary(rowsAffected)
            )
        case .unreadable:
            state(
                title: String(localized: "Can't Show This Result"),
                systemImage: "text.bubble",
                description: String(localized: "The reply is not rows the grid can draw. The conversation has it in full.")
            )
        }
    }

    private func grid(_ decoded: TableRows, for run: AgentQueryRun) -> some View {
        let rows = TableRowsSorting.sorted(decoded, by: sortState)
        return DataGridView(
            tableRowsProvider: { rows },
            changeManager: changeManager,
            isEditable: false,
            configuration: DataGridConfiguration(
                databaseType: connection?.type,
                showRowNumbers: true,
                supportsColumnCommands: false,
                supportsValueFilter: false
            ),
            delegate: gridDelegate,
            selectedRowIndices: $selectedRows,
            sortState: $sortState,
            columnLayout: $columnLayout,
            contentRevision: contentRevision(for: run)
        )
        .onAppear {
            gridDelegate.onSortStateChanged = { sortState = $0 }
        }
    }

    private func state(title: String, systemImage: String, description: String) -> some View {
        UnavailableStateView(title, systemImage: systemImage, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Grouped, because a count is read at a glance and "1,204" is legible where "1204" has to be
    /// counted. A statement that reports no count at all is one from a tool that answers in the
    /// bridge's shape without sending one.
    private static func changeSummary(_ rowsAffected: Int?) -> String {
        guard let rowsAffected else {
            return String(localized: "The statement returned no rows to show.")
        }
        guard rowsAffected > 0 else {
            return String(localized: "No rows changed.")
        }
        let template = rowsAffected == 1
            ? String(localized: "%@ row changed.")
            : String(localized: "%@ rows changed.")
        return String(format: template, rowsAffected.formatted(.number.grouping(.automatic)))
    }

    /// Moves whenever the rows the grid should be drawing move, which a sort does without changing
    /// the run.
    private func contentRevision(for run: AgentQueryRun) -> Int {
        var hasher = Hasher()
        hasher.combine(run.id)
        for column in sortState.columns {
            hasher.combine(column.columnIndex)
            hasher.combine(column.direction)
        }
        return hasher.finalize()
    }

    private func summary(of sql: String) -> String {
        let flattened = sql
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (flattened as NSString).length > 60
            ? String(flattened.prefix(57)) + "…"
            : flattened
    }
}
