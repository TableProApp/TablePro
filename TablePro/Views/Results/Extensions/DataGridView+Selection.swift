//
//  DataGridView+Selection.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    func tableViewColumnDidResize(_ notification: Notification) {
        // Only track user-initiated resizes, not programmatic ones during column rebuilds
        guard !isRebuildingColumns else { return }
        hasUserResizedColumns = true
        scheduleLayoutPersist()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isRebuildingColumns else { return }
        hasUserResizedColumns = true
        scheduleLayoutPersist()
    }

    private func scheduleLayoutPersist() {
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

        let newSelection = Set(tableView.selectedRowIndexes.map { $0 })
        if newSelection != selectedRowIndices {
            selectedRowIndices = newSelection
        }

        if let keyTableView = tableView as? KeyHandlingTableView {
            if newSelection.isEmpty {
                keyTableView.focusedRow = -1
                keyTableView.focusedColumn = -1
            } else if keyTableView.focusedRow < 0, let firstRow = newSelection.min() {
                keyTableView.focusedRow = firstRow
                keyTableView.focusedColumn = 1
            }
        }
    }
}
