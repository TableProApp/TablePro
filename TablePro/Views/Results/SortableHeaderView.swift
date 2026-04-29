//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit

@MainActor
final class SortableHeaderView: NSTableHeaderView {
    weak var coordinator: TableViewCoordinator?

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift),
              let tableView = tableView,
              let coordinator = coordinator else {
            super.mouseDown(with: event)
            return
        }

        let pointInHeader = convert(event.locationInWindow, from: nil)
        let columnIndex = column(at: pointInHeader)
        guard columnIndex >= 0, columnIndex < tableView.numberOfColumns else {
            super.mouseDown(with: event)
            return
        }

        let column = tableView.tableColumns[columnIndex]
        guard column.identifier != ColumnIdentitySchema.rowNumberIdentifier,
              let dataIndex = coordinator.dataColumnIndex(from: column.identifier) else {
            super.mouseDown(with: event)
            return
        }

        let existing = coordinator.currentSortState.columns.first(where: { $0.columnIndex == dataIndex })
        let ascending: Bool
        if existing == nil {
            ascending = true
        } else {
            ascending = false
        }
        coordinator.delegate?.dataGridSort(column: dataIndex, ascending: ascending, isMultiSort: true)
    }
}
