//
//  DataGridView+CellFilterMenu.swift
//  TablePro
//

import AppKit

internal extension TableViewCoordinator {
    func cellFilterMenuItem(
        forRow displayIndex: Int,
        dataColumn: Int,
        apply: @escaping (TableFilter) -> Void
    ) -> NSMenuItem? {
        let tableRows = tableRowsProvider()
        guard let row = displayRow(at: displayIndex, in: tableRows) else { return nil }
        let rowState = visualState(for: displayIndex)
        guard !rowState.isInserted, !rowState.isModified(columnIndex: dataColumn) else { return nil }
        let columns = tableRows.columns
        guard columns.indices.contains(dataColumn), dataColumn < row.values.count else { return nil }

        return CellFilterMenuBuilder.menuItem(
            columnName: columns[dataColumn],
            columnType: filterMenuColumnType(forDataColumn: dataColumn, in: tableRows),
            value: row.values[dataColumn],
            apply: apply
        )
    }

    func filterMenuColumnType(forDataColumn dataColumn: Int, in tableRows: TableRows) -> ColumnType? {
        let columnTypes = filterMenuColumnTypes ?? tableRows.columnTypes
        guard columnTypes.indices.contains(dataColumn) else { return nil }
        return columnTypes[dataColumn]
    }
}
