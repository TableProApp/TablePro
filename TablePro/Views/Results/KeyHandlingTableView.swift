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

    /// Currently focused row index (-1 = no focus)
    var focusedRow: Int = -1 {
        didSet {
            if oldValue != focusedRow && oldValue >= 0 {
                if focusedColumn >= 0 && focusedColumn < numberOfColumns && oldValue < numberOfRows {
                    reloadData(forRowIndexes: IndexSet(integer: oldValue),
                               columnIndexes: IndexSet(integer: focusedColumn))
                }
            }
        }
    }

    /// Currently focused column index (-1 = no focus, 0 = row number column)
    var focusedColumn: Int = -1 {
        didSet {
            guard oldValue != focusedColumn else { return }
            let row = focusedRow
            guard row >= 0 && row < numberOfRows else { return }
            var cols = IndexSet()
            if oldValue >= 0 && oldValue < numberOfColumns { cols.insert(oldValue) }
            if focusedColumn >= 0 && focusedColumn < numberOfColumns { cols.insert(focusedColumn) }
            if !cols.isEmpty {
                reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: cols)
            }
        }
    }

    /// Anchor row for Shift+Arrow range selection (-1 = no anchor)
    var selectionAnchor: Int = -1

    /// Current pivot row for Shift+Arrow navigation
    var selectionPivot: Int = -1

    // MARK: - TablePlus-Style Cell Focus

    override func mouseDown(with event: NSEvent) {
        // Become first responder to capture keyboard events (especially Delete key)
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)

        // Double-click in empty area adds a new row
        if event.clickCount == 2 && clickedRow == -1 && coordinator?.isEditable == true {
            if let callback = coordinator?.onAddRow {
                callback()
            } else {
                NotificationCenter.default.post(name: .addNewRow, object: nil)
            }
            return
        }

        // Reset anchor/pivot when clicking without Shift
        if clickedRow >= 0 && !event.modifierFlags.contains(.shift) {
            selectionAnchor = clickedRow
            selectionPivot = clickedRow
        }

        super.mouseDown(with: event)

        // Only handle editing for valid clicks on data cells (not row number column)
        guard clickedRow >= 0,
              clickedColumn >= 0,
              clickedColumn < numberOfColumns else {
            return
        }

        // Skip row number column
        let column = tableColumns[clickedColumn]
        if column.identifier.rawValue == "__rowNumber__" {
            focusedRow = -1
            focusedColumn = -1
            return
        }

        // Update focus (edit mode is triggered by double-click, not single click)
        focusedRow = clickedRow
        focusedColumn = clickedColumn
    }

    // MARK: - Standard Edit Menu Actions

    /// Delete selected rows - called from menu or keyboard shortcut
    @objc func delete(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        guard !selectedRowIndexes.isEmpty else { return }

        // Use callback if available (e.g., Structure tab), otherwise fall back to notification (Data tab)
        if let callback = coordinator?.onDeleteRows {
            callback(Set(selectedRowIndexes))
        } else {
            // Fallback for views that haven't migrated to callback pattern
            // Pass selected indices so the handler doesn't rely on SwiftUI binding sync timing
            NotificationCenter.default.post(
                name: .deleteSelectedRows,
                object: nil,
                userInfo: ["rowIndices": Set(selectedRowIndexes)]
            )
        }
    }

    /// Copy selected rows to clipboard
    @objc func copy(_ sender: Any?) {
        let indices = Set(selectedRowIndexes)
        if let callback = coordinator?.onCopyRows {
            callback(indices)
        } else {
            coordinator?.copyRows(at: indices)
        }
    }

    /// Paste rows from clipboard
    @objc func paste(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        if let callback = coordinator?.onPasteRows {
            callback()
        }
    }

    /// Undo last change
    @objc func undo(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        if let callback = coordinator?.onUndo {
            callback()
        }
    }

    /// Redo last undone change
    @objc func redo(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        if let callback = coordinator?.onRedo {
            callback()
        }
    }

    /// Validate menu items and shortcuts
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(delete(_:)), #selector(deleteBackward(_:)):
            return coordinator?.isEditable == true && !selectedRowIndexes.isEmpty
        case #selector(copy(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return coordinator?.isEditable == true && coordinator?.onPasteRows != nil
        case #selector(undo(_:)):
            return coordinator?.isEditable == true && (coordinator?.canUndo() ?? false)
        case #selector(redo(_:)):
            return coordinator?.isEditable == true && (coordinator?.canRedo() ?? false)
        case #selector(insertNewline(_:)):
            return selectedRow >= 0 && focusedColumn >= 1 && coordinator?.isEditable == true
        case #selector(cancelOperation(_:)):
            return focusedRow >= 0 || focusedColumn >= 0 || !selectedRowIndexes.isEmpty
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
            handleTabKey()
            return
        }

        // Handle arrow keys (custom Shift+selection logic)
        let row = selectedRow
        let isShiftHeld = event.modifierFlags.contains(.shift)

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

        default:
            break
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
        let columnIndex = focusedColumn - 1
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

    /// Handle ESC key - clear selection and focus
    @objc override func cancelOperation(_ sender: Any?) {
        focusedRow = -1
        focusedColumn = -1
        deselectAll(sender)
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

    /// Handle Tab key - navigate to next cell (manual implementation required for NSTableView)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow >= 0,
           let rowView = rowView(atRow: clickedRow, makeIfNecessary: false) as? TableRowViewWithMenu {
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            return rowView.menu(for: event)
        }

        return super.menu(for: event)
    }
}
