//
//  DataGridView+TypePicker.swift
//  TablePro
//
//  Extension for database-specific type picker popover in structure view.
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    func showTypePickerPopover(
        tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int
    ) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let currentValue = cellValue(at: row, column: columnIndex) ?? ""
        let dbType = databaseType ?? .mysql

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView
        ) { [weak self] dismiss in
            TypePickerContentView(
                databaseType: dbType,
                currentValue: currentValue,
                onCommit: { newValue in
                    guard let self else { return }
                    self.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }
}
