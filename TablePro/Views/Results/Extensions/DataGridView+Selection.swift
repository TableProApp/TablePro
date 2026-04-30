//
//  DataGridView+Selection.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isRebuildingColumns else { return }
        scheduleLayoutPersist()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isRebuildingColumns else { return }
        layoutPersistTask?.cancel()
        persistColumnLayoutToStorage()
    }

    func scheduleLayoutPersist() {
        layoutPersistTask?.cancel()
        layoutPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistColumnLayoutToStorage()
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        guard let tableView = notification.object as? NSTableView else { return }

        let previousSelection = selectedRowIndices
        let newSelection = Set(tableView.selectedRowIndexes.map { $0 })
        if newSelection != previousSelection {
            selectedRowIndices = newSelection
        }

        guard let keyTableView = tableView as? KeyHandlingTableView else { return }

        let newFocus = resolvedFocus(
            previous: previousSelection,
            current: newSelection,
            existingFocusedRow: keyTableView.focusedRow,
            existingFocusedColumn: keyTableView.focusedColumn,
            tableView: tableView
        )

        if keyTableView.focusedRow != newFocus.row {
            keyTableView.focusedRow = newFocus.row
        }
        if keyTableView.focusedColumn != newFocus.column {
            keyTableView.focusedColumn = newFocus.column
        }
    }

    private func resolvedFocus(
        previous: Set<Int>,
        current: Set<Int>,
        existingFocusedRow: Int,
        existingFocusedColumn: Int,
        tableView: NSTableView
    ) -> (row: Int, column: Int) {
        if current.isEmpty {
            return (-1, -1)
        }

        let column = existingFocusedColumn >= 1 ? existingFocusedColumn : 1
        let added = current.subtracting(previous)

        if let tip = added.max() {
            return (tip, column)
        }

        let removed = previous.subtracting(current)
        if let lostTip = removed.max(),
           let currentMax = current.max(),
           let currentMin = current.min() {
            let row = lostTip > currentMax ? currentMax : currentMin
            return (row, column)
        }

        if existingFocusedRow >= 0, current.contains(existingFocusedRow) {
            return (existingFocusedRow, column)
        }

        return (current.min() ?? -1, column)
    }
}
