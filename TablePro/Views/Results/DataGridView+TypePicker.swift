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

        let currentValue = rowProvider.value(atRow: row, column: columnIndex) ?? ""
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
                    let oldValue = self.rowProvider.value(atRow: row, column: columnIndex)
                    guard oldValue != newValue else { return }

                    self.rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
                    self.onCellEdit?(row, columnIndex, newValue)

                    tableView.reloadData(
                        forRowIndexes: IndexSet(integer: row),
                        columnIndexes: IndexSet(integer: column)
                    )
                },
                onDismiss: dismiss
            )
        }
    }
}
