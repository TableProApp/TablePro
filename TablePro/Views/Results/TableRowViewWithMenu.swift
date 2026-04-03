//
//  TableRowViewWithMenu.swift
//  TablePro
//
//  Custom row view with context menu support.
//  Extracted from DataGridView for better maintainability.
//

import AppKit

/// Custom row view that provides context menu for row operations
final class TableRowViewWithMenu: NSTableRowView {
    weak var coordinator: TableViewCoordinator?
    var rowIndex: Int = 0

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator = coordinator,
              let tableView = coordinator.tableView else { return nil }

        // Determine which column was clicked
        let locationInRow = convert(event.locationInWindow, from: nil)
        let locationInTable = tableView.convert(locationInRow, from: self)
        let clickedColumn = tableView.column(at: locationInTable)

        // Adjust for row number column (index 0)
        let dataColumnIndex = clickedColumn > 0 ? clickedColumn - 1 : -1

        let menu = NSMenu()

        if coordinator.changeManager.isRowDeleted(rowIndex) {
            menu.addItem(
                withTitle: String(localized: "Undo Delete"), action: #selector(undoDeleteRow), keyEquivalent: ""
            ).target = self
        }

        if !coordinator.changeManager.isRowDeleted(rowIndex) {
            // Copy
            let copyItem = NSMenuItem(
                title: String(localized: "Copy"), action: #selector(copySelectedOrCurrentRow), keyEquivalent: "c")
            copyItem.keyEquivalentModifierMask = .command
            copyItem.target = self
            menu.addItem(copyItem)

            // "Copy as" submenu — always includes Cell Value + With Headers, conditionally adds SQL statements
            let copyAsMenu = NSMenu()

            if dataColumnIndex >= 0 {
                let copyCellItem = NSMenuItem(
                    title: String(localized: "Cell Value"), action: #selector(copyCellValue(_:)),
                    keyEquivalent: "")
                copyCellItem.representedObject = dataColumnIndex
                copyCellItem.target = self
                copyAsMenu.addItem(copyCellItem)
            }

            let copyWithHeadersItem = NSMenuItem(
                title: String(localized: "With Headers"),
                action: #selector(copySelectedOrCurrentRowWithHeaders),
                keyEquivalent: "c")
            copyWithHeadersItem.keyEquivalentModifierMask = [.command, .shift]
            copyWithHeadersItem.target = self
            copyAsMenu.addItem(copyWithHeadersItem)

            let jsonItem = NSMenuItem(
                title: String(localized: "JSON"),
                action: #selector(copyAsJson),
                keyEquivalent: "")
            jsonItem.target = self
            copyAsMenu.addItem(jsonItem)

            if let dbType = coordinator.databaseType,
               dbType != .mongodb && dbType != .redis,
               coordinator.tableName != nil {
                copyAsMenu.addItem(NSMenuItem.separator())

                let insertItem = NSMenuItem(
                    title: String(localized: "INSERT Statement(s)"),
                    action: #selector(copyAsInsert),
                    keyEquivalent: "")
                insertItem.target = self
                copyAsMenu.addItem(insertItem)

                let updateItem = NSMenuItem(
                    title: String(localized: "UPDATE Statement(s)"),
                    action: #selector(copyAsUpdate),
                    keyEquivalent: "")
                updateItem.target = self
                copyAsMenu.addItem(updateItem)
            }

            let copyAsItem = NSMenuItem(title: String(localized: "Copy as"), action: nil, keyEquivalent: "")
            copyAsItem.submenu = copyAsMenu
            menu.addItem(copyAsItem)

            // Paste
            if coordinator.isEditable {
                let pasteItem = NSMenuItem(
                    title: String(localized: "Paste"), action: #selector(pasteRows), keyEquivalent: "v")
                pasteItem.keyEquivalentModifierMask = .command
                pasteItem.target = self
                menu.addItem(pasteItem)
            }

            // FK actions (only for FK columns with non-empty values)
            if dataColumnIndex >= 0, dataColumnIndex < coordinator.rowProvider.columns.count {
                let columnName = coordinator.rowProvider.columns[dataColumnIndex]
                if let fkInfo = coordinator.rowProvider.columnForeignKeys[columnName],
                   let cellValue = coordinator.rowProvider.value(atRow: rowIndex, column: dataColumnIndex),
                   !cellValue.isEmpty {
                    menu.addItem(NSMenuItem.separator())

                    let previewItem = NSMenuItem(
                        title: String(localized: "Preview Referenced Row"),
                        action: #selector(previewForeignKey(_:)),
                        keyEquivalent: ""
                    )
                    previewItem.representedObject = dataColumnIndex
                    previewItem.target = self
                    menu.addItem(previewItem)

                    let navItem = NSMenuItem(
                        title: String(format: String(localized: "Open %@"), fkInfo.referencedTable),
                        action: #selector(navigateToForeignKey(_:)),
                        keyEquivalent: ""
                    )
                    navItem.representedObject = dataColumnIndex
                    navItem.target = self
                    menu.addItem(navItem)
                }
            }

            if coordinator.isEditable {
                menu.addItem(NSMenuItem.separator())
            }

            // Set Value (editable + column clicked)
            if coordinator.isEditable && dataColumnIndex >= 0 {
                let setValueMenu = NSMenu()

                let emptyItem = NSMenuItem(
                    title: String(localized: "Empty"), action: #selector(setEmptyValue(_:)), keyEquivalent: "")
                emptyItem.representedObject = dataColumnIndex
                emptyItem.target = self
                setValueMenu.addItem(emptyItem)

                let nullItem = NSMenuItem(
                    title: String(localized: "NULL"), action: #selector(setNullValue(_:)), keyEquivalent: "")
                nullItem.representedObject = dataColumnIndex
                nullItem.target = self
                setValueMenu.addItem(nullItem)

                let defaultItem = NSMenuItem(
                    title: String(localized: "Default"), action: #selector(setDefaultValue(_:)), keyEquivalent: "")
                defaultItem.representedObject = dataColumnIndex
                defaultItem.target = self
                setValueMenu.addItem(defaultItem)

                let setValueItem = NSMenuItem(title: String(localized: "Set Value"), action: nil, keyEquivalent: "")
                setValueItem.submenu = setValueMenu
                menu.addItem(setValueItem)
            }

            // Export Results
            menu.addItem(NSMenuItem.separator())

            let exportItem = NSMenuItem(
                title: String(localized: "Export Results..."),
                action: #selector(exportResults),
                keyEquivalent: ""
            )
            exportItem.target = self
            menu.addItem(exportItem)

            // Duplicate & Delete
            if coordinator.isEditable {
                let duplicateItem = NSMenuItem(
                    title: String(localized: "Duplicate"), action: #selector(duplicateRow), keyEquivalent: "d")
                duplicateItem.keyEquivalentModifierMask = .command
                duplicateItem.target = self
                menu.addItem(duplicateItem)

                let deleteItem = NSMenuItem(
                    title: String(localized: "Delete"),
                    action: #selector(deleteRow),
                    keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter).map { Character($0) } ?? "\u{8}")
                )
                deleteItem.keyEquivalentModifierMask = []
                deleteItem.target = self
                menu.addItem(deleteItem)
            }
        }

        return menu
    }

    @objc private func deleteRow() {
        let indices: Set<Int> = if let selected = coordinator?.selectedRowIndices, !selected.isEmpty {
            selected
        } else {
            [rowIndex]
        }
        NotificationCenter.default.post(
            name: .deleteSelectedRows,
            object: nil,
            userInfo: ["rowIndices": indices]
        )
    }

    @objc private func duplicateRow() {
        NotificationCenter.default.post(name: .duplicateRow, object: nil)
    }

    @objc private func undoDeleteRow() {
        coordinator?.undoDeleteRow(at: rowIndex)
    }

    @objc private func undoInsertRow() {
        coordinator?.undoInsertRow(at: rowIndex)
    }

    @objc private func copyRow() {
        coordinator?.copyRows(at: [rowIndex])
    }

    @objc private func copySelectedRows() {
        guard let selectedIndices = coordinator?.selectedRowIndices else { return }
        coordinator?.copyRows(at: selectedIndices)
    }

    @objc private func copySelectedOrCurrentRowWithHeaders() {
        guard let coordinator = coordinator else { return }
        let indices: Set<Int> = !coordinator.selectedRowIndices.isEmpty
            ? coordinator.selectedRowIndices
            : [rowIndex]
        coordinator.copyRowsWithHeaders(at: indices)
    }

    @objc private func copySelectedOrCurrentRow() {
        guard let coordinator = coordinator else { return }
        let indices: Set<Int> = !coordinator.selectedRowIndices.isEmpty
            ? coordinator.selectedRowIndices
            : [rowIndex]
        if let callback = coordinator.onCopyRows {
            callback(indices)
        } else {
            coordinator.copyRows(at: indices)
        }
    }

    @objc private func pasteRows() {
        NotificationCenter.default.post(name: .pasteRows, object: nil)
    }

    @objc private func copyCellValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.copyCellValue(at: rowIndex, columnIndex: columnIndex)
    }

    @objc private func setNullValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.setCellValueAtColumn(nil, at: rowIndex, columnIndex: columnIndex)
    }

    @objc private func setEmptyValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.setCellValueAtColumn("", at: rowIndex, columnIndex: columnIndex)
    }

    @objc private func setDefaultValue(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        coordinator?.setCellValueAtColumn("__DEFAULT__", at: rowIndex, columnIndex: columnIndex)
    }

    @objc private func copyAsInsert() {
        guard let coordinator else { return }
        let indices: Set<Int> = !coordinator.selectedRowIndices.isEmpty
            ? coordinator.selectedRowIndices
            : [rowIndex]
        coordinator.copyRowsAsInsert(at: indices)
    }

    @objc private func copyAsUpdate() {
        guard let coordinator else { return }
        let indices: Set<Int> = !coordinator.selectedRowIndices.isEmpty
            ? coordinator.selectedRowIndices
            : [rowIndex]
        coordinator.copyRowsAsUpdate(at: indices)
    }

    @objc private func exportResults() {
        NotificationCenter.default.post(name: .exportQueryResults, object: nil)
    }

    @objc private func copyAsJson() {
        guard let coordinator else { return }
        let indices: Set<Int> = !coordinator.selectedRowIndices.isEmpty
            ? coordinator.selectedRowIndices
            : [rowIndex]
        coordinator.copyRowsAsJson(at: indices)
    }

    @objc private func previewForeignKey(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int,
              let coordinator, let tableView = coordinator.tableView else { return }
        coordinator.showForeignKeyPreview(
            tableView: tableView, row: rowIndex, column: columnIndex + 1, columnIndex: columnIndex
        )
    }

    @objc private func navigateToForeignKey(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int,
              let coordinator else { return }
        let columnName = coordinator.rowProvider.columns[columnIndex]
        guard let fkInfo = coordinator.rowProvider.columnForeignKeys[columnName],
              let value = coordinator.rowProvider.value(atRow: rowIndex, column: columnIndex) else { return }
        coordinator.onNavigateFK?(value, fkInfo)
    }
}
