//
//  KeyHandlingTableView.swift
//  TablePro
//
//  NSTableView subclass that handles keyboard shortcuts and TablePlus-style cell focus.
//  Uses Apple's responder chain pattern with interpretKeyEvents for standard shortcuts.
//
//  Architecture:
//  - Keyboard events → interpretKeyEvents → Standard selectors (@objc moveUp, delete, etc.)
//  - Uses KeyCode enum for readability (no magic numbers)
//  - Responder chain validation via validateUserInterfaceItem
//

import AppKit

/// NSTableView subclass that handles keyboard shortcuts and TablePlus-style cell focus on click
final class KeyHandlingTableView: NSTableView {
    weak var coordinator: TableViewCoordinator?

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool {
        true
    }

    var selection = TableSelection() {
        didSet {
            guard let (rows, columns) = selection.reloadIndexes(from: oldValue) else { return }
            let validRows = rows.filteredIndexSet { $0 < numberOfRows }
            let validColumns = columns.filteredIndexSet { $0 < numberOfColumns }
            guard !validRows.isEmpty, !validColumns.isEmpty else { return }
            reloadData(forRowIndexes: validRows, columnIndexes: validColumns)
        }
    }

    var focusedRow: Int {
        get { selection.focusedRow }
        set { selection.focusedRow = newValue }
    }

    var focusedColumn: Int {
        get { selection.focusedColumn }
        set { selection.focusedColumn = newValue }
    }

    var selectionAnchor: Int {
        get { selection.anchor }
        set { selection.anchor = newValue }
    }

    var selectionPivot: Int {
        get { selection.pivot }
        set { selection.pivot = newValue }
    }

    // MARK: - TablePlus-Style Cell Focus

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)

        if event.clickCount == 2 && clickedRow == -1 && coordinator?.isEditable == true {
            coordinator?.delegate?.dataGridAddRow()
            return
        }

        if clickedRow >= 0 && !event.modifierFlags.contains(.shift) {
            selectionAnchor = clickedRow
            selectionPivot = clickedRow
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
        if column.identifier.rawValue == "__rowNumber__" {
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

    // MARK: - Standard Edit Menu Actions

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

    // MARK: - Keyboard Handling

    /// Convert key events to standard selectors using interpretKeyEvents
    /// This enables proper responder chain behavior and accessibility support
    override func keyDown(with event: NSEvent) {
        guard let key = KeyCode(rawValue: event.keyCode) else {
            super.keyDown(with: event)
            return
        }

        // Handle Tab manually (NSTableView cell navigation requires custom logic)
        if key == .tab {
            if event.modifierFlags.contains(.shift) {
                handleShiftTabKey()
            } else {
                handleTabKey()
            }
            return
        }

        let row = selectedRow
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShiftHeld = modifiers.contains(.shift)

        if modifiers.contains(.control) {
            switch key {
            case .h:
                handleLeftArrow(currentRow: row)
                return
            case .j:
                handleDownArrow(currentRow: row, isShiftHeld: isShiftHeld)
                return
            case .k:
                handleUpArrow(currentRow: row, isShiftHeld: isShiftHeld)
                return
            case .l:
                handleRightArrow(currentRow: row)
                return
            default:
                break
            }
        }

        switch key {
        case .upArrow:
            handleUpArrow(currentRow: row, isShiftHeld: isShiftHeld)
            return

        case .downArrow:
            handleDownArrow(currentRow: row, isShiftHeld: isShiftHeld)
            return

        case .leftArrow:
            handleLeftArrow(currentRow: row)
            return

        case .rightArrow:
            handleRightArrow(currentRow: row)
            return

        case .home:
            handleHome(isShiftHeld: isShiftHeld)
            return

        case .end:
            handleEnd(isShiftHeld: isShiftHeld)
            return

        case .pageUp:
            handlePageUp(isShiftHeld: isShiftHeld)
            return

        case .pageDown:
            handlePageDown(isShiftHeld: isShiftHeld)
            return

        default:
            break
        }

        // FK preview: dispatch from user-configurable shortcut (default: Space)
        if let fkCombo = AppSettingsManager.shared.keyboard.shortcut(for: .previewFKReference),
           !fkCombo.isCleared,
           fkCombo.matches(event),
           selectedRow >= 0, focusedColumn >= 1 {
            coordinator?.toggleForeignKeyPreview(
                tableView: self, row: selectedRow, column: focusedColumn, columnIndex: focusedColumn - 1
            )
            return
        }

        // For all other keys, use interpretKeyEvents to map to standard selectors
        // This handles Return → insertNewline(_:), Delete → deleteBackward(_:), ESC → cancelOperation(_:)
        interpretKeyEvents([event])
    }

    // MARK: - Standard Responder Selectors

    /// Handle Return/Enter key - start editing current cell
    @objc override func insertNewline(_ sender: Any?) {
        let row = selectedRow
        guard row >= 0, focusedColumn >= 1, coordinator?.isEditable == true else {
            return
        }

        // Multiline values use overlay editor instead of field editor
        let columnIndex = DataGridView.dataColumnIndex(for: focusedColumn)
        if let value = coordinator?.rowProvider.value(atRow: row, column: columnIndex),
           value.containsLineBreak {
            coordinator?.showOverlayEditor(tableView: self, row: row, column: focusedColumn, columnIndex: columnIndex, value: value)
            return
        }

        editColumn(focusedColumn, row: row, with: nil, select: true)
    }

    /// Handle Delete/Backspace key - delete selected rows
    @objc override func deleteBackward(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        guard !selectedRowIndexes.isEmpty else { return }
        delete(sender)
    }

    @objc override func cancelOperation(_ sender: Any?) {
    }

    // MARK: - Arrow Key and Tab Helpers

    /// Handle left arrow key - move focus to previous column
    private func handleLeftArrow(currentRow: Int) {
        if focusedColumn > 1 {
            focusedColumn -= 1
            if currentRow >= 0 { scrollColumnToVisible(focusedColumn) }
        } else if focusedColumn == -1 && numberOfColumns > 1 {
            focusedColumn = numberOfColumns - 1
            if currentRow >= 0 { scrollColumnToVisible(focusedColumn) }
        }
    }

    /// Handle right arrow key - move focus to next column
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

    // MARK: - Arrow Key Selection Helpers

    private func handleUpArrow(currentRow: Int, isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }

        if currentRow == -1 {
            let targetRow = numberOfRows - 1
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
            return
        }

        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }

            let currentPivot = selectionPivot >= 0 ? selectionPivot : currentRow
            let targetRow = max(0, currentPivot - 1)
            selectionPivot = targetRow

            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            let range = IndexSet(integersIn: startRow...endRow)
            selectRowIndexes(range, byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        } else {
            let targetRow = max(0, currentRow - 1)
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        }
    }

    private func handleDownArrow(currentRow: Int, isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }

        if currentRow == -1 {
            selectionAnchor = 0
            selectionPivot = 0
            focusedRow = 0
            selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            scrollRowToVisible(0)
            return
        }

        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }

            let currentPivot = selectionPivot >= 0 ? selectionPivot : currentRow
            let targetRow = min(numberOfRows - 1, currentPivot + 1)
            selectionPivot = targetRow

            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            let range = IndexSet(integersIn: startRow...endRow)
            selectRowIndexes(range, byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        } else {
            let targetRow = min(numberOfRows - 1, currentRow + 1)
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
        }
    }

    private func handleHome(isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }
        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = selectedRow >= 0 ? selectedRow : 0
                selectionPivot = selectionAnchor
            }
            selectionPivot = 0
            let range = IndexSet(integersIn: 0...selectionAnchor)
            selectRowIndexes(range, byExtendingSelection: false)
        } else {
            selectionAnchor = 0
            selectionPivot = 0
            focusedRow = 0
            selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        scrollRowToVisible(0)
    }

    private func handleEnd(isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }
        let lastRow = numberOfRows - 1
        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = selectedRow >= 0 ? selectedRow : lastRow
                selectionPivot = selectionAnchor
            }
            selectionPivot = lastRow
            let range = IndexSet(integersIn: selectionAnchor...lastRow)
            selectRowIndexes(range, byExtendingSelection: false)
        } else {
            selectionAnchor = lastRow
            selectionPivot = lastRow
            focusedRow = lastRow
            selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        }
        scrollRowToVisible(lastRow)
    }

    private func handlePageUp(isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }
        let visibleRows = max(1, Int(visibleRect.height / rowHeight) - 1)
        let currentRow = selectedRow >= 0 ? selectedRow : 0
        let targetRow = max(0, currentRow - visibleRows)

        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }
            selectionPivot = targetRow
            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            selectRowIndexes(IndexSet(integersIn: startRow...endRow), byExtendingSelection: false)
        } else {
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        }
        scrollRowToVisible(targetRow)
    }

    private func handlePageDown(isShiftHeld: Bool) {
        guard numberOfRows > 0 else { return }
        let visibleRows = max(1, Int(visibleRect.height / rowHeight) - 1)
        let currentRow = selectedRow >= 0 ? selectedRow : 0
        let lastRow = numberOfRows - 1
        let targetRow = min(lastRow, currentRow + visibleRows)

        if isShiftHeld {
            if selectionAnchor == -1 {
                selectionAnchor = currentRow
                selectionPivot = currentRow
            }
            selectionPivot = targetRow
            let startRow = min(selectionAnchor, selectionPivot)
            let endRow = max(selectionAnchor, selectionPivot)
            selectRowIndexes(IndexSet(integersIn: startRow...endRow), byExtendingSelection: false)
        } else {
            selectionAnchor = targetRow
            selectionPivot = targetRow
            focusedRow = targetRow
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        }
        scrollRowToVisible(targetRow)
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

        // Empty space: ask delegate for a fallback menu (e.g., Structure tab "Add" actions)
        if let menu = coordinator?.delegate?.dataGridEmptySpaceMenu() {
            return menu
        }

        return super.menu(for: event)
    }
}
