//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit
import os

@MainActor
final class SortableHeaderView: NSTableHeaderView {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataGridSort")

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

        let ascending: Bool
        if let existing = coordinator.currentSortState.columns.first(where: { $0.columnIndex == dataIndex }) {
            ascending = existing.direction != .ascending
        } else {
            ascending = true
        }

        Self.logger.debug("SortableHeaderView intercepted shift+click: column=\(dataIndex) ascending=\(ascending)")
        coordinator.delegate?.dataGridSort(column: dataIndex, ascending: ascending, isMultiSort: true)
    }
}
