//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit

@MainActor
final class SortableHeaderView: NSTableHeaderView {
    weak var coordinator: TableViewCoordinator?

    override func mouseDown(with event: NSEvent) {
        guard let tableView = tableView,
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

        if isInResizeArea(point: pointInHeader, columnIndex: columnIndex, in: tableView) {
            super.mouseDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isMultiSort = flags.contains(.shift)
        let sortState = coordinator.currentSortState
        let existing = sortState.columns.first(where: { $0.columnIndex == dataIndex })

        if isMultiSort {
            handleMultiSortClick(coordinator: coordinator, dataIndex: dataIndex, existing: existing)
        } else {
            handleSingleSortClick(coordinator: coordinator, dataIndex: dataIndex, sortState: sortState, existing: existing)
        }
    }

    private func handleMultiSortClick(
        coordinator: TableViewCoordinator,
        dataIndex: Int,
        existing: SortColumn?
    ) {
        let ascending: Bool
        if existing == nil {
            ascending = true
        } else {
            ascending = false
        }
        coordinator.delegate?.dataGridSort(column: dataIndex, ascending: ascending, isMultiSort: true)
    }

    private func handleSingleSortClick(
        coordinator: TableViewCoordinator,
        dataIndex: Int,
        sortState: SortState,
        existing: SortColumn?
    ) {
        let isOnlyColumn = sortState.columns.count == 1 && existing != nil
        if isOnlyColumn, existing?.direction == .descending {
            coordinator.delegate?.dataGridClearSort()
            return
        }

        let ascending: Bool
        if isOnlyColumn, existing?.direction == .ascending {
            ascending = false
        } else {
            ascending = true
        }
        coordinator.delegate?.dataGridSort(column: dataIndex, ascending: ascending, isMultiSort: false)
    }

    private func isInResizeArea(point: NSPoint, columnIndex: Int, in tableView: NSTableView) -> Bool {
        let columnRect = headerRect(ofColumn: columnIndex)
        let resizeMargin: CGFloat = 4
        return point.x > columnRect.maxX - resizeMargin && point.x <= columnRect.maxX + resizeMargin
    }
}
