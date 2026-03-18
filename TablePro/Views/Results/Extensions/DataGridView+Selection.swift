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
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isRebuildingColumns else { return }
        hasUserResizedColumns = true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        guard let tableView = notification.object as? NSTableView else { return }

        let newSelection = Set(tableView.selectedRowIndexes.map { $0 })
        if newSelection != selectedRowIndices {
            DispatchQueue.main.async { [weak self] in
                self?.selectedRowIndices = newSelection
            }
        }

        if let keyTableView = tableView as? KeyHandlingTableView {
            if newSelection.isEmpty {
                keyTableView.focusedRow = -1
                keyTableView.focusedColumn = -1
            }
        }
    }
}
