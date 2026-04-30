import AppKit

final class KeyHandlingTableView: NSTableView {
    weak var coordinator: TableViewCoordinator?

    override var acceptsFirstResponder: Bool {
        true
    }

    var selection = TableSelection() {
        didSet {
            guard let (rows, columns) = selection.reloadIndexes(from: oldValue) else { return }
            scheduleFocusReload(rows: rows, columns: columns)
        }
    }

    private var pendingFocusReloadRows: IndexSet?
    private var pendingFocusReloadColumns: IndexSet?

    private func scheduleFocusReload(rows: IndexSet, columns: IndexSet) {
        if pendingFocusReloadRows != nil {
            pendingFocusReloadRows?.formUnion(rows)
            pendingFocusReloadColumns?.formUnion(columns)
            return
        }
        pendingFocusReloadRows = rows
        pendingFocusReloadColumns = columns
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingFocusReload()
        }
    }

    private func flushPendingFocusReload() {
        guard let pendingRows = pendingFocusReloadRows,
              let pendingColumns = pendingFocusReloadColumns else { return }
        pendingFocusReloadRows = nil
        pendingFocusReloadColumns = nil
        let validRows = pendingRows.filteredIndexSet { $0 < numberOfRows }
        let validColumns = pendingColumns.filteredIndexSet { $0 < numberOfColumns }
        guard !validRows.isEmpty, !validColumns.isEmpty else { return }
        reloadData(forRowIndexes: validRows, columnIndexes: validColumns)
    }

    var focusedRow: Int {
        get { selection.focusedRow }
        set { selection.focusedRow = newValue }
    }

    var focusedColumn: Int {
        get { selection.focusedColumn }
        set { selection.focusedColumn = newValue }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)

        if event.clickCount == 2 && clickedRow == -1 && coordinator?.isEditable == true {
            coordinator?.delegate?.dataGridAddRow()
            return
        }

        let alreadyFocusedHere = clickedRow >= 0
            && clickedColumn >= 0
            && clickedRow == focusedRow
            && clickedColumn == focusedColumn

        super.mouseDown(with: event)

        guard clickedRow >= 0,
              clickedColumn >= 0,
              clickedColumn < numberOfColumns else {
            return
        }

        let column = tableColumns[clickedColumn]
        if column.identifier == ColumnIdentitySchema.rowNumberIdentifier {
            focusedRow = -1
            focusedColumn = -1
            return
        }

        focusedRow = clickedRow
        focusedColumn = clickedColumn

        if alreadyFocusedHere && event.clickCount == 1 && selectedRowIndexes.count == 1 {
            let dataColumnIndex = DataGridView.dataColumnIndex(for: clickedColumn)
            if coordinator?.canStartInlineEdit(row: clickedRow, columnIndex: dataColumnIndex) == true {
                editColumn(clickedColumn, row: clickedRow, with: nil, select: true)
            }
        }
    }

    @objc func delete(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        guard !selectedRowIndexes.isEmpty else { return }
        coordinator?.delegate?.dataGridDeleteRows(Set(selectedRowIndexes))
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.delegate?.dataGridCopyRows(Set(selectedRowIndexes))
    }

    @objc func paste(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        if focusedRow >= 0, focusedColumn >= 1 {
            let dataCol = DataGridView.dataColumnIndex(for: focusedColumn)
            if coordinator?.pasteCellsFromClipboard(anchorRow: focusedRow, anchorColumn: dataCol) == true {
                return
            }
        }
        coordinator?.delegate?.dataGridPasteRows()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(delete(_:)), #selector(deleteBackward(_:)):
            return coordinator?.isEditable == true && !selectedRowIndexes.isEmpty
        case #selector(copy(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return coordinator?.isEditable == true && coordinator?.delegate != nil
        case #selector(insertNewline(_:)):
            return selectedRow >= 0 && focusedColumn >= 1 && coordinator?.isEditable == true
        case #selector(cancelOperation(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let key = KeyCode(rawValue: event.keyCode) else {
            super.keyDown(with: event)
            return
        }

        if key == .tab {
            if event.modifierFlags.contains(.shift) {
                handleShiftTabKey()
            } else {
                handleTabKey()
            }
            return
        }

        let row = selectedRow

        switch key {
        case .leftArrow:
            handleLeftArrow(currentRow: row)
            return

        case .rightArrow:
            handleRightArrow(currentRow: row)
            return

        case .upArrow, .downArrow, .home, .end, .pageUp, .pageDown:
            super.keyDown(with: event)
            return

        default:
            break
        }

        if let fkCombo = AppSettingsManager.shared.keyboard.shortcut(for: .previewFKReference),
           !fkCombo.isCleared,
           fkCombo.matches(event),
           selectedRow >= 0, focusedColumn >= 1 {
            coordinator?.toggleForeignKeyPreview(
                tableView: self, row: selectedRow, column: focusedColumn, columnIndex: focusedColumn - 1
            )
            return
        }

        interpretKeyEvents([event])
    }

    @objc override func insertNewline(_ sender: Any?) {
        let row = selectedRow
        guard row >= 0, focusedColumn >= 1, coordinator?.isEditable == true else {
            return
        }

        let columnIndex = DataGridView.dataColumnIndex(for: focusedColumn)
        if let value = coordinator?.cellValue(at: row, column: columnIndex),
           value.containsLineBreak {
            coordinator?.showOverlayEditor(tableView: self, row: row, column: focusedColumn, columnIndex: columnIndex, value: value)
            return
        }

        editColumn(focusedColumn, row: row, with: nil, select: true)
    }

    @objc override func deleteBackward(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        guard !selectedRowIndexes.isEmpty else { return }
        delete(sender)
    }

    @objc override func cancelOperation(_ sender: Any?) {
    }

    private func handleLeftArrow(currentRow: Int) {
        if focusedColumn > 1 {
            focusedColumn -= 1
            if currentRow >= 0 { scrollColumnToVisible(focusedColumn) }
        } else if focusedColumn == -1 && numberOfColumns > 1 {
            focusedColumn = numberOfColumns - 1
            if currentRow >= 0 { scrollColumnToVisible(focusedColumn) }
        }
    }

    private func handleRightArrow(currentRow: Int) {
        if focusedColumn >= 1 && focusedColumn < numberOfColumns - 1 {
            focusedColumn += 1
            if currentRow >= 0 { scrollColumnToVisible(focusedColumn) }
        } else if focusedColumn == -1 && numberOfColumns > 1 {
            focusedColumn = 1
            if currentRow >= 0 { scrollColumnToVisible(focusedColumn) }
        }
    }

    private func handleTabKey() {
        let row = selectedRow
        guard row >= 0, focusedColumn >= 1 else { return }

        var nextColumn = focusedColumn + 1
        var nextRow = row

        if nextColumn >= numberOfColumns {
            nextColumn = 1
            nextRow += 1
        }
        if nextRow >= numberOfRows {
            nextRow = numberOfRows - 1
            nextColumn = numberOfColumns - 1
        }

        selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        focusedRow = nextRow
        focusedColumn = nextColumn
        scrollRowToVisible(nextRow)
        scrollColumnToVisible(nextColumn)
    }

    private func handleShiftTabKey() {
        let row = selectedRow
        guard row >= 0, focusedColumn >= 1 else { return }

        var prevColumn = focusedColumn - 1
        var prevRow = row

        if prevColumn < 1 {
            prevColumn = numberOfColumns - 1
            prevRow -= 1
        }
        if prevRow < 0 {
            prevRow = 0
            prevColumn = 1
        }

        selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
        focusedRow = prevRow
        focusedColumn = prevColumn
        scrollRowToVisible(prevRow)
        scrollColumnToVisible(prevColumn)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow >= 0,
           let rowView = rowView(atRow: clickedRow, makeIfNecessary: false) {
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            return rowView.menu(for: event)
        }

        if let menu = coordinator?.delegate?.dataGridEmptySpaceMenu() {
            return menu
        }

        return super.menu(for: event)
    }
}
