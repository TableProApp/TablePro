//
//  DataGridView+Popovers.swift
//  TablePro
//

import AppKit
import SwiftUI

// MARK: - Popover Editors

extension TableViewCoordinator {
    func showDatePickerPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = rowProvider.value(atRow: row, column: columnIndex)
        let columnType = rowProvider.columnTypes[columnIndex]

        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        DatePickerPopoverController.shared.show(
            relativeTo: cellRect,
            of: tableView,
            value: currentValue,
            columnType: columnType
        ) { [weak self] newValue in
            guard let self = self else { return }
            let oldValue = self.rowProvider.value(atRow: row, column: columnIndex)
            guard oldValue != newValue else { return }

            let columnName = self.rowProvider.columns[columnIndex]
            self.changeManager.recordCellChange(
                rowIndex: row,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: oldValue,
                newValue: newValue,
                originalRow: self.rowProvider.rowValues(at: row) ?? []
            )

            self.rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
            self.onCellEdit?(row, columnIndex, newValue)

            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }
    }

    func showForeignKeyPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, fkInfo: ForeignKeyInfo) {
        let currentValue = rowProvider.value(atRow: row, column: columnIndex)

        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }
        guard let databaseType, let connectionId else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 420, height: 320)
        ) { [weak self] dismiss in
            ForeignKeyPopoverContentView(
                currentValue: currentValue,
                fkInfo: fkInfo,
                connectionId: connectionId,
                databaseType: databaseType,
                onCommit: { newValue in
                    self?.commitPopoverEdit(
                        tableView: tableView,
                        row: row,
                        column: column,
                        columnIndex: columnIndex,
                        newValue: newValue
                    )
                },
                onDismiss: dismiss
            )
        }
    }

    func toggleForeignKeyPreview(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        if let popover = activeFKPreviewPopover, popover.isShown {
            popover.close()
            activeFKPreviewPopover = nil
            return
        }
        showForeignKeyPreview(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
    }

    func showForeignKeyPreview(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard columnIndex >= 0, columnIndex < rowProvider.columns.count else { return }
        let columnName = rowProvider.columns[columnIndex]
        guard let fkInfo = rowProvider.columnForeignKeys[columnName] else { return }
        let cellValue = rowProvider.value(atRow: row, column: columnIndex)
        guard let databaseType, let connectionId else { return }
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        let popover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 380, height: 400)
        ) { [weak self] dismiss in
            ForeignKeyPreviewView(
                cellValue: cellValue,
                fkInfo: fkInfo,
                connectionId: connectionId,
                databaseType: databaseType,
                onNavigate: {
                    dismiss()
                    guard let value = cellValue else { return }
                    self?.onNavigateFK?(value, fkInfo)
                },
                onDismiss: dismiss
            )
        }
        activeFKPreviewPopover = popover
    }

    func showJSONEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = rowProvider.value(atRow: row, column: columnIndex)

        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 420, height: 340)
        ) { [weak self] dismiss in
            JSONEditorContentView(
                initialValue: currentValue,
                onCommit: { newValue in
                    self?.commitPopoverEdit(
                        tableView: tableView,
                        row: row,
                        column: column,
                        columnIndex: columnIndex,
                        newValue: newValue
                    )
                },
                onDismiss: dismiss
            )
        }
    }

    func showBlobEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = rowProvider.value(atRow: row, column: columnIndex)

        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 520, height: 400)
        ) { [weak self] dismiss in
            HexEditorContentView(
                initialValue: currentValue,
                onCommit: { newValue in
                    self?.commitPopoverEdit(
                        tableView: tableView,
                        row: row,
                        column: column,
                        columnIndex: columnIndex,
                        newValue: newValue
                    )
                },
                onDismiss: dismiss
            )
        }
    }

    func showEnumPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }
        let columnName = rowProvider.columns[columnIndex]
        guard let allowedValues = rowProvider.columnEnumValues[columnName] else { return }

        let currentValue = rowProvider.value(atRow: row, column: columnIndex)
        let isNullable = rowProvider.columnNullable[columnName] ?? true

        var values: [String] = []
        if isNullable {
            values.append("\u{2300} NULL")
        }
        values.append(contentsOf: allowedValues)

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView
        ) { [weak self] dismiss in
            EnumPopoverContentView(
                allValues: values,
                currentValue: currentValue,
                isNullable: isNullable,
                onCommit: { newValue in
                    self?.commitPopoverEdit(tableView: tableView, row: row, column: column, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    func showSetPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }
        let columnName = rowProvider.columns[columnIndex]
        guard let allowedValues = rowProvider.columnEnumValues[columnName] else { return }

        let currentValue = rowProvider.value(atRow: row, column: columnIndex)

        let currentSet: Set<String>
        if let value = currentValue {
            currentSet = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        } else {
            currentSet = []
        }
        var selections: [String: Bool] = [:]
        for value in allowedValues {
            selections[value] = currentSet.contains(value)
        }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView
        ) { [weak self] dismiss in
            SetPopoverContentView(
                allowedValues: allowedValues,
                initialSelections: selections,
                onCommit: { newValue in
                    self?.commitPopoverEdit(tableView: tableView, row: row, column: column, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    func showDropdownMenu(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let currentValue = rowProvider.value(atRow: row, column: columnIndex)
        pendingDropdownRow = row
        pendingDropdownColumn = columnIndex
        pendingDropdownTableView = tableView

        let menu = NSMenu()
        for option in ["YES", "NO"] {
            let item = NSMenuItem(title: option, action: #selector(dropdownMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            if option == currentValue {
                item.state = .on
            }
            menu.addItem(item)
        }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        menu.popUp(positioning: nil, at: NSPoint(x: cellRect.minX, y: cellRect.maxY), in: tableView)
    }

    @objc func dropdownMenuItemSelected(_ sender: NSMenuItem) {
        guard let tableView = pendingDropdownTableView else { return }
        commitPopoverEdit(
            tableView: tableView,
            row: pendingDropdownRow,
            column: pendingDropdownColumn + 1,
            columnIndex: pendingDropdownColumn,
            newValue: sender.title
        )
    }

    func commitPopoverEdit(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, newValue: String?) {
        let oldValue = rowProvider.value(atRow: row, column: columnIndex)
        guard oldValue != newValue else { return }

        let columnName = rowProvider.columns[columnIndex]
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: rowProvider.rowValues(at: row) ?? []
        )

        rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
        onCellEdit?(row, columnIndex, newValue)

        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
    }
}
