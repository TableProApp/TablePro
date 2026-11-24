import Foundation
import TableProDatabase
import TableProModels

// What Export Results and the Select bar's Export hand the export sheet for a query's rows.
enum QueryResultsExport {
    // A read runs again for every row where the engine can hold it to read-only and a fresh connection reads what the
    // session read; anything else exports the rows on screen, which may be a cut result.
    static func resultScope(
        _ viewModel: QueryEditorViewModel,
        databaseType: DatabaseType,
        coordinator: ConnectionCoordinator
    ) throws(ClipboardExporter.IncompleteValues) -> ExportScopeOption {
        switch try viewModel.resultsExportSource(
            databaseType: databaseType,
            runsReadOnly: coordinator.session?.driver.enforcesReadOnlyMode ?? false,
            reproducible: coordinator.reproducesOnFreshConnection(viewModel.resultPlacement)
        ) {
        case .rerun(let statement):
            return ExportScopeOption(
                kind: .result,
                source: .rerun(statement),
                detail: String(localized: "Runs the query again and exports every row it returns.")
            )
        case .buffered(let rows):
            return ExportScopeOption(
                kind: .result,
                source: .rows(rows),
                detail: String(format: String(localized: "Exports the %d rows shown."), viewModel.bufferedRowCount)
            )
        }
    }

    static func selectionScope(
        columns: [ColumnInfo],
        rows: [Row],
        indices: [Int]
    ) throws(ClipboardExporter.IncompleteValues) -> ExportScopeOption {
        let picked = indices.filter(rows.indices.contains).map { rows[$0].cells }
        let rowSet = try ExportRowSet(columns: columns, cells: picked)
        return ExportScopeOption(kind: .selectedRows, source: .rows(rowSet), detail: selectedRowsDetail(picked.count))
    }

    static func selectedRowsDetail(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) row](inflect: true) selected.").characters)
    }

    // Off the main actor, so a large pick formats without holding up the screen.
    @concurrent
    nonisolated static func clipboardText(
        _ rows: [[Cell]],
        columns: [ColumnInfo],
        format: ExportFormat,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) async throws -> String {
        try ClipboardExporter.exportRows(
            columns: columns, rows: rows, format: format, databaseType: databaseType, driver: driver
        )
    }
}
