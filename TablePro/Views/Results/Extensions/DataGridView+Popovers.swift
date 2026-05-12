//
//  DataGridView+Popovers.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

// MARK: - Popover Editors

extension TableViewCoordinator {
    func cellValue(at row: Int, column columnIndex: Int) -> String? {
        guard let displayRow = displayRow(at: row), columnIndex >= 0, columnIndex < displayRow.values.count else {
            return nil
        }
        return displayRow.values[columnIndex].asText
    }

    func cellTypedValue(at row: Int, column columnIndex: Int) -> PluginCellValue {
        guard let displayRow = displayRow(at: row), columnIndex >= 0, columnIndex < displayRow.values.count else {
            return .null
        }
        return displayRow.values[columnIndex]
    }

    func showForeignKeyPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, fkInfo: ForeignKeyInfo) {
        let currentValue = cellValue(at: row, column: columnIndex)

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
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    func toggleForeignKeyPreview(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        if let popover = activeFKPreviewPopover, popover.isShown {
            popover.close()
            clearFKPreviewState()
            return
        }
        showForeignKeyPreview(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
    }

    func showForeignKeyPreview(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let fkInfo = tableRows.columnForeignKeys[columnName] else { return }
        let cellValue = cellValue(at: row, column: columnIndex)
        guard let databaseType, let connectionId else { return }
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let model = FKPreviewModel(cellValue: cellValue, fkInfo: fkInfo)
        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        let popover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 380, height: 400)
        ) { [weak self] dismiss in
            ForeignKeyPreviewView(
                model: model,
                connectionId: connectionId,
                databaseType: databaseType,
                onNavigate: { [weak self, model] in
                    dismiss()
                    guard let value = model.cellValue else { return }
                    self?.delegate?.dataGridNavigateFK(value: value, fkInfo: model.fkInfo)
                },
                onDismiss: dismiss
            )
        }
        activeFKPreviewPopover = popover
        activeFKPreviewModel = model
        activeFKPreviewColumnIndex = columnIndex
    }

    func clearFKPreviewState() {
        activeFKPreviewPopover = nil
        activeFKPreviewModel = nil
        activeFKPreviewColumnIndex = nil
    }

    func refreshFKPreviewForRowChange() {
        guard let popover = activeFKPreviewPopover, popover.isShown,
              let model = activeFKPreviewModel,
              let columnIndex = activeFKPreviewColumnIndex,
              let tableView else {
            return
        }
        let focusedRow = (tableView as? KeyHandlingTableView)?.focusedRow ?? -1
        let newRow = focusedRow >= 0 ? focusedRow : (tableView.selectedRowIndexes.max() ?? -1)
        guard newRow >= 0,
              let tableColumnIndex = DataGridView.tableColumnIndex(
                for: columnIndex,
                in: tableView,
                schema: identitySchema
              ) else {
            popover.close()
            clearFKPreviewState()
            return
        }
        let tableRows = tableRowsProvider()
        guard columnIndex < tableRows.columns.count,
              let fkInfo = tableRows.columnForeignKeys[tableRows.columns[columnIndex]] else {
            popover.close()
            clearFKPreviewState()
            return
        }
        let newValue = cellValue(at: newRow, column: columnIndex)
        let newRect = tableView.rect(ofRow: newRow).intersection(tableView.rect(ofColumn: tableColumnIndex))
        guard !newRect.isEmpty else {
            popover.close()
            clearFKPreviewState()
            return
        }
        model.cellValue = newValue
        model.fkInfo = fkInfo
        popover.positioningRect = newRect
    }

    func dismissFKPreviewOnColumnChange() {
        guard let popover = activeFKPreviewPopover, popover.isShown else { return }
        popover.close()
        clearFKPreviewState()
    }

    func showJSONEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = cellValue(at: row, column: columnIndex)
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]

        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: nil
        ) { [weak self] dismiss in
            JSONEditorContentView(
                initialValue: currentValue,
                columnName: columnName,
                onCommit: { newValue in
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss,
                onPopOut: { currentText in
                    dismiss()
                    JSONViewerWindowController.open(
                        text: currentText,
                        columnName: columnName,
                        isEditable: true,
                        onCommit: { newValue in
                            self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                        }
                    )
                }
            )
        }
    }

    func showBlobEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let typed = cellTypedValue(at: row, column: columnIndex)
        let currentValue: String?
        switch typed {
        case .null: currentValue = nil
        case .text(let s): currentValue = s
        case .bytes(let data): currentValue = String(data: data, encoding: .isoLatin1)
        }

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
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onCommitBytes: { data in
                    self?.commitBinaryEdit(row: row, columnIndex: columnIndex, data: data)
                },
                onDismiss: dismiss
            )
        }
    }

    func showEnumPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let allowedValues = tableRows.columnEnumValues[columnName] else { return }

        let currentValue = cellValue(at: row, column: columnIndex)
        let isNullable = tableRows.columnNullable[columnName] ?? true

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
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    func showSetPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let allowedValues = tableRows.columnEnumValues[columnName] else { return }

        let currentValue = cellValue(at: row, column: columnIndex)

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
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    func showDropdownMenu(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }

        let currentValue = cellValue(at: row, column: columnIndex)
        let context = DropdownMenuContext(row: row, columnIndex: columnIndex)

        let options: [String]
        if let custom = customDropdownOptions?[columnIndex] {
            options = custom
        } else if let dbType = databaseType, PluginManager.shared.usesTrueFalseBooleans(for: dbType) {
            options = ["true", "false"]
        } else {
            options = ["1", "0"]
        }

        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(title: option, action: #selector(dropdownMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = context
            if option == currentValue {
                item.state = .on
            }
            menu.addItem(item)
        }

        let columnName = tableRows.columns[columnIndex]
        let isNullable = tableRows.columnNullable[columnName] ?? true
        if isNullable && customDropdownOptions?[columnIndex] == nil {
            menu.addItem(.separator())
            let nullItem = NSMenuItem(
                title: String(localized: "Set NULL"),
                action: #selector(dropdownMenuNullSelected(_:)),
                keyEquivalent: ""
            )
            nullItem.target = self
            nullItem.representedObject = context
            if currentValue == nil {
                nullItem.state = .on
            }
            menu.addItem(nullItem)
        }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        menu.popUp(positioning: nil, at: NSPoint(x: cellRect.minX, y: cellRect.maxY), in: tableView)
    }

    @objc func dropdownMenuItemSelected(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? DropdownMenuContext else { return }
        commitPopoverEdit(row: context.row, columnIndex: context.columnIndex, newValue: sender.title)
    }

    @objc func dropdownMenuNullSelected(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? DropdownMenuContext else { return }
        commitPopoverEdit(row: context.row, columnIndex: context.columnIndex, newValue: nil)
    }

    func commitPopoverEdit(row: Int, columnIndex: Int, newValue: String?) {
        commitCellEdit(row: row, columnIndex: columnIndex, newValue: newValue)
    }

    func commitBinaryEdit(row: Int, columnIndex: Int, data: Data) {
        commitTypedCellEdit(row: row, columnIndex: columnIndex, newValue: .bytes(data))
    }
}

private final class DropdownMenuContext {
    let row: Int
    let columnIndex: Int

    init(row: Int, columnIndex: Int) {
        self.row = row
        self.columnIndex = columnIndex
    }
}
