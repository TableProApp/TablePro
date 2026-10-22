//
//  DataGridView+UnloadedValues.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    // False while the rows' unloaded values load; `retry` runs once every one has arrived, and only
    // while each display position still shows the row it showed, since `retry` addresses positions.
    func unloadedValuesAreLoaded(
        displayRows: some Sequence<Int>,
        columns: IndexSet? = nil,
        retry: @escaping @MainActor () -> Void
    ) -> Bool {
        let positions = Array(displayRows)
        let tableRows = tableRowsProvider()
        let shown = positions.map { displayRow(at: $0, in: tableRows) }
        let ids = shown.compactMap { $0 }
            .filter { row in row.unloadedColumns.keys.contains { columns?.contains($0) ?? true } }
            .map(\.id)
        guard !ids.isEmpty else { return true }
        guard let delegate else {
            NSSound.beep()
            return false
        }
        let shownIDs = shown.map { $0?.id }
        delegate.dataGridLoadUnloadedValues(rowIDs: ids, columns: columns) { [weak self] loaded in
            guard let self else { return }
            let current = self.tableRowsProvider()
            guard loaded, positions.map({ self.displayRow(at: $0, in: current)?.id }) == shownIDs else {
                NSSound.beep()
                return
            }
            retry()
        }
        return false
    }

    func unloadedValuesAreLoaded(targets: [SetValueTarget], retry: @escaping @MainActor () -> Void) -> Bool {
        unloadedValuesAreLoaded(
            displayRows: Set(targets.map(\.displayRow)),
            columns: IndexSet(targets.map(\.columnIndex)),
            retry: retry
        )
    }

    func isUnloaded(row: Int, columnIndex: Int) -> Bool {
        displayRow(at: row)?.unloadedByteCount(columnIndex) != nil
    }
}
