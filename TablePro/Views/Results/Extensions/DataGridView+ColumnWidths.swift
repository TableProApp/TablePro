//
//  DataGridView+ColumnWidths.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func automaticColumnWidth(for columnName: String, columnIndex: Int, tableRows: TableRows) -> CGFloat {
        cellFactory.calculateOptimalColumnWidth(
            for: columnName,
            columnIndex: columnIndex,
            tableRows: tableRows,
            accessory: columnPresentation(for: columnIndex, in: tableRows).accessory,
            displayFormat: columnIndex < columnDisplayFormats.count ? columnDisplayFormats[columnIndex] : nil,
            databaseType: databaseType,
            isLargeDataset: isLargeDataset,
            nullDisplayString: cellRegistry.nullDisplayString
        )
    }

    func fitToContentColumnWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows,
        availableWidth: CGFloat,
        fittedColumnCount: Int = 1
    ) -> CGFloat {
        cellFactory.calculateFitToContentWidth(
            for: columnName,
            columnIndex: columnIndex,
            tableRows: tableRows,
            availableWidth: availableWidth,
            accessory: columnPresentation(for: columnIndex, in: tableRows).accessory,
            displayFormat: columnIndex < columnDisplayFormats.count ? columnDisplayFormats[columnIndex] : nil,
            databaseType: databaseType,
            isLargeDataset: isLargeDataset,
            nullDisplayString: cellRegistry.nullDisplayString,
            fittedColumnCount: fittedColumnCount
        )
    }

    /// A layout that carries widths but no content widths was written before the app recorded which
    /// widths the user chose, and it measured every column as if none of them drew an in-cell action
    /// button. Its width for a column that does draw one is short by that button's footprint, so
    /// that width is dropped and the column is measured again. A column with no button was measured
    /// with the same padding then as now, so its width is kept, and so is a width the user has taken
    /// ownership of in this session.
    func layoutDiscardingUnownedWidths(
        _ layout: ColumnLayoutState?,
        tableRows: TableRows
    ) -> ColumnLayoutState? {
        guard var layout,
              layout.columnContentWidths?.isEmpty != false,
              !layout.columnWidths.isEmpty
        else {
            unownedRestoredColumnNames = []
            return layout
        }

        for (columnIndex, columnName) in tableRows.columns.enumerated() {
            guard !userSizedColumnNames.contains(columnName),
                  columnPresentation(for: columnIndex, in: tableRows).accessory != .none
            else { continue }
            layout.columnWidths.removeValue(forKey: columnName)
        }
        unownedRestoredColumnNames = Set(layout.columnWidths.keys).subtracting(userSizedColumnNames)
        return layout
    }

    /// Metadata that reveals an action button arrives after the rows on several drivers, and the
    /// column was measured without room for it. Widening is scoped to columns the user has not
    /// sized and never shrinks one, so a width the user is reading only ever grows to fit what the
    /// cell now draws.
    func applyAccessoryWidthChanges(
        _ changes: DataGridColumnPresentationChanges,
        tableRows: TableRows
    ) {
        guard widenAutomaticColumns(forPresentationChanges: changes, tableRows: tableRows) else { return }
        redrawVisibleCells()
    }

    private func widenAutomaticColumns(
        forPresentationChanges changes: DataGridColumnPresentationChanges,
        tableRows: TableRows
    ) -> Bool {
        guard let tableView, !changes.isEmpty else { return false }

        let wasRebuildingColumns = isRebuildingColumns
        isRebuildingColumns = true
        defer { isRebuildingColumns = wasRebuildingColumns }

        var didWiden = false
        for dataIndex in changes.indices {
            guard dataIndex < tableRows.columns.count else { continue }
            let columnName = tableRows.columns[dataIndex]
            let isOwned = userSizedColumnNames.contains(columnName)
                && !unownedRestoredColumnNames.contains(columnName)
            guard !isOwned,
                  let identifier = identitySchema.identifier(for: dataIndex)
            else { continue }

            let tableColumnIndex = tableView.column(withIdentifier: identifier)
            guard tableColumnIndex >= 0, tableColumnIndex < tableView.tableColumns.count else { continue }

            let column = tableView.tableColumns[tableColumnIndex]
            let width = automaticColumnWidth(for: columnName, columnIndex: dataIndex, tableRows: tableRows)
            guard width > column.width else { continue }
            column.width = width
            didWiden = true
        }
        return didWiden
    }
}
