//
//  DataGridRowView.swift
//  TablePro
//

import AppKit
import Combine

@MainActor
class DataGridRowView: NSTableRowView {
    weak var coordinator: TableViewCoordinator?
    var rowIndex: Int = 0

    private(set) var visualState: RowVisualState = .empty
    private var rowTint: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawSubviewsIntoLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.actions = Self.disabledLayerActions
        return layer
    }

    private static let disabledLayerActions: [String: any CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
    ]

    func applyVisualState(_ state: RowVisualState) {
        guard state != visualState else { return }
        visualState = state
        let nextTint: NSColor? = if state.isDeleted {
            ThemeEngine.shared.colors.dataGrid.deleted
        } else if state.isInserted {
            ThemeEngine.shared.colors.dataGrid.inserted
        } else {
            nil
        }
        guard !colorsEqual(rowTint, nextTint) else { return }
        rowTint = nextTint
        needsDisplay = true
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            propagateEmphasisToCells()
        }
    }

    override var isEmphasized: Bool {
        didSet {
            guard isEmphasized != oldValue else { return }
            propagateEmphasisToCells()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let cell = subview as? DataGridCellView else { return }
        cell.applyEmphasizedSelection(isSelected && isEmphasized)
    }

    private func propagateEmphasisToCells() {
        let emphasized = isSelected && isEmphasized
        for subview in subviews {
            guard let cell = subview as? DataGridCellView else { continue }
            cell.applyEmphasizedSelection(emphasized)
            cell.needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let rowTint, !isSelected else { return }
        rowTint.setFill()
        bounds.fill()
    }

    private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator = coordinator,
              let tableView = coordinator.tableView else { return nil }

        let locationInRow = convert(event.locationInWindow, from: nil)
        let locationInTable = tableView.convert(locationInRow, from: self)
        let clickedColumn = tableView.column(at: locationInTable)

        let dataColumnIndex: Int = clickedColumn > 0
            ? DataGridView.dataColumnIndex(for: clickedColumn, in: tableView, schema: coordinator.identitySchema) ?? -1
            : -1

        let menu = NSMenu()

        if coordinator.changeManager.isRowDeleted(rowIndex) {
            menu.addItem(
                withTitle: String(localized: "Undo Delete"), action: #selector(undoDeleteRow), keyEquivalent: ""
            ).target = self
            return menu
        }

        let copyItem = NSMenuItem(
            title: String(localized: "Copy"), action: #selector(copySelectedOrCurrentRow), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

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
            keyEquivalent: "")
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

        if coordinator.isEditable {
            let pasteItem = NSMenuItem(
                title: String(localized: "Paste"), action: #selector(pasteRows), keyEquivalent: "")
            pasteItem.target = self
            menu.addItem(pasteItem)
        }

        let tableRows = coordinator.tableRowsProvider()
        if dataColumnIndex >= 0, dataColumnIndex < tableRows.columns.count {
            let columnName = tableRows.columns[dataColumnIndex]
            if let fkInfo = tableRows.columnForeignKeys[columnName],
               let cellValue = coordinator.cellValue(at: rowIndex, column: dataColumnIndex),
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

        if coordinator.isEditable && dataColumnIndex >= 0 {
            let setValueMenu = NSMenu()

            let emptyItem = NSMenuItem(
                title: String(localized: "Empty"), action: #selector(setEmptyValue(_:)), keyEquivalent: "")
            emptyItem.representedObject = dataColumnIndex
            emptyItem.target = self
            setValueMenu.addItem(emptyItem)

            let columnName = dataColumnIndex < tableRows.columns.count
                ? tableRows.columns[dataColumnIndex]
                : nil

            let isNullable = columnName.flatMap { tableRows.columnNullable[$0] } ?? true
            if isNullable {
                let nullItem = NSMenuItem(
                    title: String(localized: "NULL"), action: #selector(setNullValue(_:)), keyEquivalent: "")
                nullItem.representedObject = dataColumnIndex
                nullItem.target = self
                setValueMenu.addItem(nullItem)
            }

            let hasDefault = columnName.flatMap({ tableRows.columnDefaults[$0] ?? nil }) != nil
            if hasDefault {
                let defaultItem = NSMenuItem(
                    title: String(localized: "Default"), action: #selector(setDefaultValue(_:)), keyEquivalent: "")
                defaultItem.representedObject = dataColumnIndex
                defaultItem.target = self
                setValueMenu.addItem(defaultItem)
            }

            let setValueItem = NSMenuItem(title: String(localized: "Set Value"), action: nil, keyEquivalent: "")
            setValueItem.submenu = setValueMenu
            menu.addItem(setValueItem)
        }

        menu.addItem(NSMenuItem.separator())

        let exportItem = NSMenuItem(
            title: String(localized: "Export Results..."),
            action: #selector(exportResults),
            keyEquivalent: ""
        )
        exportItem.target = self
        menu.addItem(exportItem)

        if coordinator.isEditable {
            let duplicateItem = NSMenuItem(
                title: String(localized: "Duplicate"), action: #selector(duplicateRow), keyEquivalent: "")
            duplicateItem.target = self
            menu.addItem(duplicateItem)

            let deleteItem = NSMenuItem(
                title: String(localized: "Delete"),
                action: #selector(deleteRow),
                keyEquivalent: ""
            )
            deleteItem.target = self
            menu.addItem(deleteItem)
        }

        return menu
    }

    @objc private func deleteRow() {
        let indices: Set<Int> = if let selected = coordinator?.selectedRowIndices, !selected.isEmpty {
            selected
        } else {
            [rowIndex]
        }
        coordinator?.delegate?.dataGridDeleteRows(indices)
    }

    @objc private func duplicateRow() {
        coordinator?.delegate?.dataGridDuplicateRow()
    }

    @objc private func undoDeleteRow() {
        coordinator?.undoDeleteRow(at: rowIndex)
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
        coordinator.delegate?.dataGridCopyRows(indices)
    }

    @objc private func pasteRows() {
        coordinator?.delegate?.dataGridPasteRows()
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
        AppCommands.shared.exportQueryResults.send(())
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
              let coordinator, let tableView = coordinator.tableView,
              let column = DataGridView.tableColumnIndex(
                for: columnIndex,
                in: tableView,
                schema: coordinator.identitySchema
              ) else { return }
        coordinator.showForeignKeyPreview(
            tableView: tableView, row: rowIndex, column: column, columnIndex: columnIndex
        )
    }

    @objc private func navigateToForeignKey(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int,
              let coordinator else { return }
        let tableRows = coordinator.tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let fkInfo = tableRows.columnForeignKeys[columnName],
              let value = coordinator.cellValue(at: rowIndex, column: columnIndex) else { return }
        coordinator.delegate?.dataGridNavigateFK(value: value, fkInfo: fkInfo)
    }
}
