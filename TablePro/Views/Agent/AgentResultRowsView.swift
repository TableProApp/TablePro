//
//  AgentResultRowsView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// The rows a session read, drawn by the app's own data grid.
///
/// Read-only, and modelled on `CompareRowGrid`, which is the other place a grid reviews rows it does
/// not own: a change manager of its own, a constant sort state, and a column layout held in `@State`
/// so nothing reaches `FileColumnLayoutPersister`. A `DataGridConfiguration` naming only the
/// database type keeps `columnLayoutKey` nil, so an agent result can never write into a real table's
/// saved column widths.
///
/// Drawing rows by hand here was the alternative and it is worse in ways that are not obvious: the
/// grid already gives type-aware formatting, the Data Grid font (rather than a system text style,
/// which is the two-font-domain defect), column separators that scale, an accessibility cell tree,
/// selection and copy. None of that is worth reimplementing beside the real one.
internal struct AgentResultRowsView: View {
    @ObservedObject internal var session: AgentSession
    internal let connection: DatabaseConnection?

    @State private var changeManager = AnyChangeManager(DataChangeManager())
    @State private var selectedRows: Set<Int> = []
    @State private var columnLayout = ColumnLayoutState()
    @State private var selectedRunId: String?

    private var runs: [AgentQueryRun] {
        AgentArtifactProjection.build(from: session.viewModel.messages).runs
    }

    var body: some View {
        let runs = runs
        if runs.isEmpty {
            UnavailableStateView(
                String(localized: "No results yet"),
                systemImage: "tablecells",
                description: Text(String(localized: "Rows the session reads appear here."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let run = runs.first { $0.id == selectedRunId } ?? runs[runs.count - 1]
            VStack(spacing: 0) {
                runPicker(runs: runs, current: run)
                Divider()
                grid(for: run)
            }
            .onChange(of: run.id) { _ in selectedRows = [] }
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

    @ViewBuilder
    private func grid(for run: AgentQueryRun) -> some View {
        if let rows = AgentResultDecoder.tableRows(fromResultJSON: run.resultJSON) {
            DataGridView(
                tableRowsProvider: { rows },
                changeManager: changeManager,
                isEditable: false,
                configuration: DataGridConfiguration(
                    databaseType: connection?.type,
                    showRowNumbers: true,
                    supportsColumnCommands: false
                ),
                selectedRowIndices: $selectedRows,
                sortState: .constant(SortState()),
                columnLayout: $columnLayout,
                contentRevision: run.id.hashValue
            )
        } else {
            UnavailableStateView(
                String(localized: "Nothing to show"),
                systemImage: "tablecells",
                description: Text(String(localized: "This query returned no rows."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
