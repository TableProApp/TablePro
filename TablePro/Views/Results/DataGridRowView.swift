//
//  DataGridRowView.swift
//  TablePro
//

import AppKit
import Combine

@MainActor
class DataGridRowView: NSTableRowView {
    enum CopyContextTarget {
        case cell(Int)
        case row
        case unresolved
    }

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
        if let rowTint, !isSelected {
            rowTint.setFill()
            bounds.fill()
        }
        drawCellSelectionFill(in: dirtyRect)
    }

    private func drawCellSelectionFill(in dirtyRect: NSRect) {
        guard let coordinator,
              let tableView = coordinator.tableView else { return }
        let selection = coordinator.selectionController.selection
        guard !selection.isEmpty else { return }
        let columns = selection.columns(in: rowIndex)
        guard !columns.isEmpty else { return }

        let fillColor: NSColor = isSelected
            ? NSColor.unemphasizedSelectedContentBackgroundColor
            : NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28)
        fillColor.setFill()

        for dataColumn in columns {
            guard let tableColumnIndex = coordinator.tableColumnIndex(for: dataColumn) else { continue }
            let columnRect = tableView.rect(ofColumn: tableColumnIndex)
            let localRect = NSRect(x: columnRect.minX, y: 0, width: columnRect.width, height: bounds.height)
            guard localRect.intersects(dirtyRect) else { continue }
            localRect.fill()
        }
    }

    private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }

    private func addForeignKeyMenuItems(to menu: NSMenu, dataColumnIndex: Int, tableRows: TableRows) {
        guard let coordinator, dataColumnIndex >= 0, dataColumnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[dataColumnIndex]
        guard let fkInfo = tableRows.columnForeignKeys[columnName],
              let cellValue = coordinator.cellValue(at: rowIndex, column: dataColumnIndex),
              !cellValue.isEmpty else { return }

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

        let navInNewTabItem = NSMenuItem(
            title: String(format: String(localized: "Open %@ in New Tab"), fkInfo.referencedTable),
            action: #selector(navigateToForeignKeyInNewTab(_:)),
            keyEquivalent: ""
        )
        navInNewTabItem.representedObject = dataColumnIndex
        navInNewTabItem.target = self
        menu.addItem(navInNewTabItem)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator = coordinator,
              let tableView = coordinator.tableView else { return nil }

        let locationInRow = convert(event.locationInWindow, from: nil)
        let locationInTable = tableView.convert(locationInRow, from: self)
        let clickedColumn = tableView.column(at: locationInTable)

        let dataColumnIndex: Int = clickedColumn >= 0
            ? DataGridView.dataColumnIndex(for: clickedColumn, in: tableView, schema: coordinator.identitySchema) ?? -1
            : -1

        let menu = NSMenu()

        if coordinator.changeManager.isRowDeleted(rowIndex) {
            menu.addItem(
                withTitle: String(localized: "Undo Delete"), action: #selector(undoDeleteRow), keyEquivalent: ""
            ).target = self
            return menu
        }

        let copyTarget: CopyContextTarget = if dataColumnIndex >= 0 {
            .cell(dataColumnIndex)
        } else if clickedColumn >= 0 {
            .row
        } else {
            .unresolved
        }

        let copyItem = NSMenuItem(
            title: String(localized: "Copy"), action: #selector(copyFromContextMenu(_:)), keyEquivalent: "")
        copyItem.representedObject = copyTarget
        copyItem.target = self
        menu.addItem(copyItem)

        let copyAsMenu = NSMenu()

        let copyRowsItem = NSMenuItem(
            title: String(localized: "Rows"),
            action: #selector(copySelectedOrCurrentRow),
            keyEquivalent: ""
        )
        copyRowsItem.target = self
        copyAsMenu.addItem(copyRowsItem)

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

        let csvItem = NSMenuItem(
            title: String(localized: "CSV"),
            action: #selector(copyAsCsv),
            keyEquivalent: "")
        csvItem.target = self
        copyAsMenu.addItem(csvItem)

        let csvHeadersItem = NSMenuItem(
            title: String(localized: "CSV with Headers"),
            action: #selector(copyAsCsvWithHeaders),
            keyEquivalent: "")
        csvHeadersItem.target = self
        copyAsMenu.addItem(csvHeadersItem)

        let markdownItem = NSMenuItem(
            title: String(localized: "Markdown"),
            action: #selector(copyAsMarkdown),
            keyEquivalent: "")
        markdownItem.target = self
        copyAsMenu.addItem(markdownItem)

        if dataColumnIndex >= 0 {
            let inClauseItem = NSMenuItem(
                title: String(localized: "IN Clause"),
                action: #selector(copyAsInClause(_:)),
                keyEquivalent: "")
            inClauseItem.representedObject = dataColumnIndex
            inClauseItem.target = self
            copyAsMenu.addItem(inClauseItem)
        }

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
        addForeignKeyMenuItems(to: menu, dataColumnIndex: dataColumnIndex, tableRows: tableRows)

        if coordinator.isEditable {
            menu.addItem(NSMenuItem.separator())
        }

        if coordinator.isEditable && dataColumnIndex >= 0 {
            let setValueItem = NSMenuItem(title: String(localized: "Set Value"), action: nil, keyEquivalent: "")
            setValueItem.submenu = buildSetValueMenu(dataColumnIndex: dataColumnIndex, tableRows: tableRows)
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

        if coordinator.delegate?.dataGridCanClearResults() == true {
            let clearResultsItem = NSMenuItem(
                title: String(localized: "Clear Results"),
                action: #selector(clearResults),
                keyEquivalent: ""
            )
            clearResultsItem.target = self
            menu.addItem(clearResultsItem)
        }

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

    private func buildSetValueMenu(dataColumnIndex: Int, tableRows: TableRows) -> NSMenu {
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

        let columnType: ColumnType? = dataColumnIndex < tableRows.columnTypes.count
            ? tableRows.columnTypes[dataColumnIndex]
            : nil
        if let columnType, columnType.isDateType {
            setValueMenu.addItem(.separator())
            for function in Self.dateValueFunctions(for: columnType) {
                let item = NSMenuItem(
                    title: function, action: #selector(setSqlFunctionValue(_:)), keyEquivalent: "")
                item.representedObject = DateSetterContext(columnIndex: dataColumnIndex, value: function)
                item.target = self
                setValueMenu.addItem(item)
            }
        }

        return setValueMenu
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

    private func selectedOrCurrentIndices(in coordinator: TableViewCoordinator) -> Set<Int> {
        coordinator.selectedRowIndices.isEmpty ? [rowIndex] : coordinator.selectedRowIndices
    }

    @objc private func copySelectedOrCurrentRowWithHeaders() {
        guard let coordinator else { return }
        coordinator.copyRowsWithHeaders(at: selectedOrCurrentIndices(in: coordinator))
    }

    @objc private func copySelectedOrCurrentRow() {
        guard let coordinator else { return }
        coordinator.delegate?.dataGridCopyRows(selectedOrCurrentIndices(in: coordinator))
    }

    @objc private func copyFromContextMenu(_ sender: NSMenuItem) {
        guard let coordinator else { return }
        if !coordinator.selectionController.isEmpty {
            coordinator.copyGridSelection(coordinator.selectionController.selection)
            return
        }
        switch sender.representedObject as? CopyContextTarget {
        case .cell(let columnIndex):
            coordinator.copyCellValue(at: rowIndex, columnIndex: columnIndex)
        case .unresolved:
            if let columnIndex = focusedDataColumnIndex(in: coordinator) {
                coordinator.copyCellValue(at: rowIndex, columnIndex: columnIndex)
            } else {
                copySelectedOrCurrentRow()
            }
        case .row, .none:
            copySelectedOrCurrentRow()
        }
    }

    @objc private func pasteRows() {
        coordinator?.delegate?.dataGridPasteRows()
    }

    private func focusedDataColumnIndex(in coordinator: TableViewCoordinator) -> Int? {
        guard let tableView = coordinator.tableView as? KeyHandlingTableView,
              tableView.focusedRow == rowIndex,
              DataGridView.isDataTableColumn(tableView.focusedColumn) else { return nil }
        return DataGridView.dataColumnIndex(
            for: tableView.focusedColumn,
            in: tableView,
            schema: coordinator.identitySchema
        )
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

    @objc private func setSqlFunctionValue(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? DateSetterContext else { return }
        coordinator?.setCellValueAtColumn(context.value, at: rowIndex, columnIndex: context.columnIndex)
    }

    static func dateValueFunctions(for columnType: ColumnType) -> [String] {
        switch columnType {
        case .date:
            return ["CURRENT_DATE"]
        case .timestamp, .datetime:
            return columnType.isTimeOnly
                ? ["CURRENT_TIME"]
                : ["NOW()", "CURRENT_TIMESTAMP"]
        default:
            return []
        }
    }

    @objc private func copyAsInsert() {
        guard let coordinator else { return }
        coordinator.copyRowsAsInsert(at: selectedOrCurrentIndices(in: coordinator))
    }

    @objc private func copyAsUpdate() {
        guard let coordinator else { return }
        coordinator.copyRowsAsUpdate(at: selectedOrCurrentIndices(in: coordinator))
    }

    @objc private func exportResults() {
        AppCommands.shared.exportQueryResults.send(())
    }

    @objc private func clearResults() {
        coordinator?.delegate?.dataGridClearResults()
    }

    @objc private func copyAsJson() {
        guard let coordinator else { return }
        coordinator.copyRowsAsJson(at: selectedOrCurrentIndices(in: coordinator))
    }

    @objc private func copyAsCsv() {
        guard let coordinator else { return }
        coordinator.copyRowsAsCsv(at: selectedOrCurrentIndices(in: coordinator), includeHeaders: false)
    }

    @objc private func copyAsCsvWithHeaders() {
        guard let coordinator else { return }
        coordinator.copyRowsAsCsv(at: selectedOrCurrentIndices(in: coordinator), includeHeaders: true)
    }

    @objc private func copyAsMarkdown() {
        guard let coordinator else { return }
        coordinator.copyRowsAsMarkdown(at: selectedOrCurrentIndices(in: coordinator))
    }

    @objc private func copyAsInClause(_ sender: NSMenuItem) {
        guard let coordinator, let columnIndex = sender.representedObject as? Int else { return }
        coordinator.copyRowsAsInClause(at: selectedOrCurrentIndices(in: coordinator), columnIndex: columnIndex)
    }

    @objc private func previewForeignKey(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int,
              let coordinator, let tableView = coordinator.tableView,
              let column = coordinator.tableColumnIndex(for: columnIndex) else { return }
        coordinator.showForeignKeyPreview(
            tableView: tableView, row: rowIndex, column: column, columnIndex: columnIndex
        )
    }

    @objc private func navigateToForeignKey(_ sender: NSMenuItem) {
        performForeignKeyNavigation(from: sender, openInNewTab: false)
    }

    @objc private func navigateToForeignKeyInNewTab(_ sender: NSMenuItem) {
        performForeignKeyNavigation(from: sender, openInNewTab: true)
    }

    private func performForeignKeyNavigation(from sender: NSMenuItem, openInNewTab: Bool) {
        guard let columnIndex = sender.representedObject as? Int,
              let coordinator else { return }
        let tableRows = coordinator.tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let fkInfo = tableRows.columnForeignKeys[columnName],
              let value = coordinator.cellValue(at: rowIndex, column: columnIndex) else { return }
        coordinator.delegate?.dataGridNavigateFK(value: value, fkInfo: fkInfo, openInNewTab: openInNewTab)
    }
}

private final class DateSetterContext {
    let columnIndex: Int
    let value: String

    init(columnIndex: Int, value: String) {
        self.columnIndex = columnIndex
        self.value = value
    }
}
