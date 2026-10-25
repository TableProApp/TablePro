//
//  AgentResultRowsView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

// The rows a session read, drawn read-only by the app's own grid. They are held in full and there is no
// query to re-run, so a header click sorts them here.
internal struct AgentResultRowsView: View {
    internal let runs: [AgentQueryRun]
    internal let artifacts: AgentArtifactCache
    internal let connection: DatabaseConnection?

    @State private var selectedRunId: String?
    @State private var loadedRunId: String?
    @StateObject private var grid = HeldRowsGridAdapter(configuration: DataGridConfiguration(), sortsHeldRows: true)

    var body: some View {
        if runs.isEmpty {
            UnavailableStateView(
                String(localized: "No Results Yet"),
                systemImage: "tablecells",
                description: Text(String(localized: "Rows the session reads appear here."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gridStandInBackground()
        } else {
            let run = runs.first { $0.id == selectedRunId } ?? runs[runs.count - 1]
            VStack(spacing: 0) {
                runPicker(runs: runs, current: run)
                Divider()
                result(for: run)
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

    @ViewBuilder
    private func result(for run: AgentQueryRun) -> some View {
        switch artifacts.payload(for: run) {
        case .rows(let decoded):
            rowsGrid(decoded, for: run)
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

    private func rowsGrid(_ decoded: TableRows, for run: AgentQueryRun) -> some View {
        // task(id:) runs with this body's values; onChange(of:) would run with the previous body's (measured).
        DataGridView(model: grid.model)
            .task(id: run.id) { load(decoded, for: run) }
    }

    // Another run starts with no selection, sort or display formats; the same run keeps them across a remount.
    private func load(_ decoded: TableRows, for run: AgentQueryRun) {
        grid.model.configuration = configuration
        guard loadedRunId != run.id else { return }
        if loadedRunId != nil {
            grid.model.clearSelection()
            grid.showSort(SortState())
            grid.model.store.displayFormats = []
        }
        loadedRunId = run.id
        grid.setRows(decoded)
    }

    private var configuration: DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.traits = DataGridEngineTraits(databaseType: connection?.type)
        configuration.showRowNumbers = true
        configuration.supportsValueFilter = false
        configuration.appliesRowCopyFormat = true
        configuration.commands = [.freezeColumns, .displayAs]
        return configuration
    }

    private func state(title: String, systemImage: String, description: String) -> some View {
        UnavailableStateView(title, systemImage: systemImage, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gridStandInBackground()
    }

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

    private func summary(of sql: String) -> String {
        let flattened = sql
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (flattened as NSString).length > 60
            ? String(flattened.prefix(57)) + "…"
            : flattened
    }
}
