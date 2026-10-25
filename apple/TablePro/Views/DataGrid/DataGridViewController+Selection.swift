//
//  DataGridViewController+Selection.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension DataGridViewController {
    var selectionContext: GridSelectionContext {
        GridSelectionContext(rowCount: model.rowCount, columnCount: model.columns.count)
    }

    // Every rectangle spans all columns: AppKit's own row movement and type-select then drive it.
    var selectionIsCellRange: Bool {
        let selection = model.selection
        return !selection.isEmpty && selection.mode == .cells
    }

    // MARK: - Model to tables

    func selectionDidChange() {
        let previous = drawnSelection
        let current = model.selection
        drawnSelection = current
        mirrorSelection()
        repaintSelection(from: previous, to: current)
        updateHighlightedColumns(current)
        postSelectionAccessibility(from: previous, to: current)
        selectionSummaryTracker.selectionDidChange()
        editingSelectionDidChange()
    }

    // A change that kept the selection on its records moved it; nothing to announce, only to repaint.
    func selectionDidMove() {
        let previous = drawnSelection
        let current = model.selection
        guard previous != current else { return }
        drawnSelection = current
        repaintSelection(from: previous, to: current)
        updateHighlightedColumns(current)
        selectionSummaryTracker.selectionDidChange()
    }

    // Both tables hold the rows the selection spans; deferred while a structural change has not reached them yet.
    func mirrorSelection() {
        let rowCount = model.rowCount
        guard panes.allSatisfy({ $0.tableView.numberOfRows == rowCount }) else { return }
        let rows = model.selection.affectedRows.filteredIndexSet { $0 >= 0 && $0 < rowCount }
        let wasMirroring = isMirroringSelection
        isMirroringSelection = true
        for pane in panes where pane.tableView.selectedRowIndexes != rows {
            pane.tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        isMirroringSelection = wasMirroring
    }

    private func repaintSelection(from previous: GridSelection, to current: GridSelection) {
        var dirty = previous.affectedRows.union(current.affectedRows)
        for cell in [previous.activeCell, current.activeCell].compactMap({ $0 }) {
            dirty.insert(cell.row)
        }
        redrawRows(dirty)
    }

    // A native change in the main table (Up, Down, type-select) goes to the model first, then mirrors.
    func tableSelectionDidChange(in pane: DataGridPane) {
        guard !isMirroringSelection else { return }
        let next = GridSelectionReducer.rowsSelectedNatively(
            pane.tableView.selectedRowIndexes,
            previous: model.selection,
            in: selectionContext
        )
        model.setSelection(next)
        mirrorSelection()
    }

    // MARK: - Keyboard

    func moveSelection(_ direction: GridMoveDirection, extending: Bool, toEdge: Bool) {
        applyKeyboardSelection(GridSelectionReducer.move(
            model.selection,
            direction,
            extending: extending,
            toEdge: toEdge,
            in: selectionContext
        ))
    }

    func moveToColumnEdge(last: Bool, extending: Bool) {
        applyKeyboardSelection(GridSelectionReducer.moveToColumnEdge(
            model.selection,
            last: last,
            extending: extending,
            in: selectionContext
        ))
    }

    // False leaves the grid through the key view loop: with no cell to start from, Tab has nowhere to go inside.
    func tabToCell(forward: Bool) -> Bool {
        let current = model.selection
        guard current.activeCell != nil || current.anchor != nil || !current.isEmpty else { return false }
        applyKeyboardSelection(GridSelectionReducer.tab(current, forward: forward, in: selectionContext))
        return true
    }

    // Escape drops a range to its active cell, then the cell or rows to nothing; false passes the key on.
    func cancelSelection() -> Bool {
        let current = model.selection
        guard !current.isEmpty else { return false }
        let next = GridSelectionReducer.cancel(current, in: selectionContext)
        model.setSelection(next)
        if next.isEmpty {
            let wasMirroring = isMirroringSelection
            isMirroringSelection = true
            panes.forEach { $0.tableView.deselectAll(nil) }
            isMirroringSelection = wasMirroring
        }
        mirrorSelection()
        return true
    }

    func widenSelectionToRows() {
        applyKeyboardSelection(GridSelectionReducer.widenToRows(model.selection, in: selectionContext))
    }

    private func applyKeyboardSelection(_ next: GridSelection) {
        model.setSelection(next)
        mirrorSelection()
        revealActiveCell()
    }

    // Shift+Space widens to rows; Space toggles the checkbox column where one exists, else previews the reference.
    func handleGridKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isSpace = KeyCode(rawValue: event.keyCode) == .space
        if isSpace, modifiers == .shift {
            widenSelectionToRows()
            return true
        }
        if isSpace, modifiers.isEmpty, !model.configuration.checkboxColumns.isEmpty, toggleCheckboxesForSelection() {
            return true
        }
        if let shortcut = AppSettingsManager.shared.keyboard.shortcut(for: .previewFKReference),
           !shortcut.isCleared,
           shortcut.matches(event) {
            toggleForeignKeyPreview()
            return true
        }
        return false
    }

    // MARK: - Checkboxes

    // Sets every selected checkbox the same way, the way a list of mail messages marks them: on unless all are on.
    func toggleCheckboxesForSelection() -> Bool {
        guard let dataIndex = model.configuration.checkboxColumns.min(),
              let column = model.columns.columns.first(where: { $0.dataIndex == dataIndex }),
              let dataSource = model.dataSource else { return false }
        let states = model.selectedRowIDs.compactMap { rowID in
            dataSource.gridCheckboxState(for: rowID, column: column).map { (rowID: rowID, isOn: $0) }
        }
        guard !states.isEmpty else { return false }
        let everyRowChecked = states.allSatisfy { $0.isOn }
        model.actions?.gridSetCheckbox(!everyRowChecked, rowIDs: states.map { $0.rowID }, column: column)
        redrawRows(model.selection.affectedRows)
        return true
    }

    @discardableResult
    func toggleCheckbox(rowID: RowID, column: DataGridColumn, displayRow: Int) -> Bool {
        guard let isOn = model.dataSource?.gridCheckboxState(for: rowID, column: column) else { return false }
        model.actions?.gridSetCheckbox(!isOn, rowIDs: [rowID], column: column)
        redrawRows(IndexSet(integer: displayRow))
        return true
    }

    // MARK: - Reveal

    func reveal(row: Int, displayColumn: Int?) {
        let table = main.tableView
        guard row >= 0, row < table.numberOfRows else { return }
        table.scrollRowToVisible(row)
        if let displayColumn {
            revealColumn(displayColumn)
        }
    }

    // Horizontal only; a frozen column is on screen at every offset.
    func revealColumn(_ displayColumn: Int) {
        let table = main.tableView
        guard displayColumn >= effectiveFrozenCount,
              let index = main.tableIndex(forDisplayPosition: displayColumn, columns: model.columns) else { return }
        let columnRect = table.rect(ofColumn: index)
        let visible = table.visibleRect
        _ = table.scrollToVisible(NSRect(x: columnRect.minX, y: visible.midY, width: columnRect.width, height: 1))
    }

    func revealActiveCell() {
        guard let active = model.selection.activeCell else { return }
        reveal(row: active.row, displayColumn: active.displayColumn)
    }

    // MARK: - Pointer

    private func pointerModifiers(_ event: NSEvent) -> GridPointerModifiers {
        var modifiers: GridPointerModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    // A press in either pane resolves through the container and the column set to one global cell.
    func tableMouseDown(_ table: DataGridTableView, with event: NSEvent) {
        guard let pane = container.pane(of: table) else {
            table.performNativeMouseDown(with: event)
            return
        }
        view.window?.makeFirstResponder(main.tableView)
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        let tableColumn = table.column(at: point)
        let modifiers = pointerModifiers(event)

        if event.clickCount == 2, row < 0 {
            handleDoubleClickBelowRows()
            return
        }
        guard row >= 0 else {
            if event.clickCount == 1, modifiers.isEmpty {
                model.clearSelection()
                mirrorSelection()
            }
            return
        }
        guard tableColumn >= 0, let slot = pane.slot(atTableIndex: tableColumn, columns: model.columns) else {
            // Past the last column the press lands on the row, which AppKit selects and tracks as in any table.
            if modifiers.isEmpty {
                model.setSelection(GridSelectionReducer.rowsSelectedNatively(
                    IndexSet(integer: row),
                    previous: model.selection,
                    in: selectionContext
                ))
                mirrorSelection()
            }
            table.performNativeMouseDown(with: event)
            return
        }

        switch slot {
        case .rowNumber:
            // AppKit tracks a press on the frozen row number itself, so a sideways drag can lift the rows it picks.
            if pane.kind == .frozen, canDragRows(fromRowNumberAt: row), !modifiers.contains(.command), !modifiers.contains(.shift) {
                model.setSelection(GridSelectionReducer.rowNumberDragPress(
                    model.selection,
                    row: row,
                    keepsPickedRows: !model.configuration.rowReorder.isEnabled,
                    in: selectionContext
                ))
                mirrorSelection()
                table.performNativeMouseDown(with: event)
                return
            }
            guard event.clickCount == 1 else { return }
            let (selection, drag) = GridSelectionReducer.rowHeaderPress(model.selection, row: row, modifiers: modifiers, in: selectionContext)
            model.setSelection(selection)
            mirrorSelection()
            trackDrag(drag, from: GridCoord(row: row, displayColumn: drag.origin.displayColumn))
        case .data(let id):
            guard let position = model.columns.displayPosition(of: id) else { return }
            let cell = GridCoord(row: row, displayColumn: position)
            if handleAccessoryPress(at: point, in: table, row: row, tableColumn: tableColumn, cell: cell, event: event) {
                return
            }
            if event.clickCount >= 2 {
                handleCellDoubleClick(at: cell)
                return
            }
            let current = model.selection
            // The cursor's cell on the one row a click selected, or a lone selected cell: a second click edits it.
            let pressesActiveCell = current.activeCell == cell && !current.picksRows
                && current.affectedRows == IndexSet(integer: cell.row)
                && (!current.hasMultipleCells || current.mode == .cursor)
            let (selection, drag) = GridSelectionReducer.press(model.selection, at: cell, modifiers: modifiers, in: selectionContext)
            model.setSelection(selection)
            mirrorSelection()
            let moved = trackDrag(drag, from: cell)
            if !moved, modifiers.isEmpty, pressesActiveCell {
                handleClickOnActiveCell(cell)
            }
        }
    }

    // Runs until mouse-up, autoscrolling the main pane; the point decides which pane names the cell.
    @discardableResult
    private func trackDrag(_ drag: GridSelectionDrag, from start: GridCoord) -> Bool {
        guard let window = view.window else { return false }
        var moved = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            _ = main.tableView.autoscroll(with: event)
            guard let cell = dragCell(at: event.locationInWindow, rowsOnly: drag.mode == .rows) else { continue }
            if drag.mode == .rows ? cell.row != start.row : cell != start {
                moved = true
            }
            model.setSelection(GridSelectionReducer.drag(drag, to: cell, in: selectionContext))
            mirrorSelection()
        }
        return moved
    }

    private func dragCell(at windowPoint: NSPoint, rowsOnly: Bool) -> GridCoord? {
        let rowCount = model.rowCount
        let columns = model.columns
        guard rowCount > 0, !columns.isEmpty else { return nil }
        let pane = container.pane(at: container.convert(windowPoint, from: nil))
        let table = pane.tableView
        let point = table.convert(windowPoint, from: nil)
        guard let row = GridSelectionReducer.dragIndex(
            hit: table.row(at: point),
            coordinate: point.y,
            first: 0,
            last: rowCount - 1,
            lastMaxEdge: table.rect(ofRow: rowCount - 1).maxY
        ) else { return nil }
        guard !rowsOnly else { return GridCoord(row: row, displayColumn: 0) }

        let hit = table.column(at: point)
        if hit >= 0, case .data(let id)? = pane.slot(atTableIndex: hit, columns: columns),
           let position = columns.displayPosition(of: id) {
            return GridCoord(row: row, displayColumn: position)
        }
        let positions = pane.displayPositions(columns: columns)
        if hit >= 0 || positions.isEmpty {
            return GridCoord(row: row, displayColumn: positions.first ?? firstColumnRightOfFrozenPane())
        }
        let last = positions.last ?? 0
        return GridCoord(row: row, displayColumn: point.x >= pane.columnsWidth ? last : positions.first ?? 0)
    }

    // Over the row numbers alone, a drag reveals what the pane covers and names the column at its edge.
    private func firstColumnRightOfFrozenPane() -> Int {
        let table = main.tableView
        let clip = main.scrollView.contentView.bounds
        let edge = container.frozenPaneWidth
        if clip.minX > 0 {
            table.scroll(NSPoint(x: max(0, clip.minX - edge), y: clip.minY))
        }
        let x = main.scrollView.contentView.bounds.minX + edge
        let hit = table.column(at: NSPoint(x: x, y: clip.minY))
        guard hit >= 0, case .data(let id)? = main.slot(atTableIndex: hit, columns: model.columns) else { return 0 }
        return model.columns.displayPosition(of: id) ?? 0
    }

    // FK arrow (Command opens a new tab), chevron and checkbox are hit-tested here and consume the press.
    private func handleAccessoryPress(
        at point: NSPoint,
        in table: DataGridTableView,
        row: Int,
        tableColumn: Int,
        cell: GridCoord,
        event: NSEvent
    ) -> Bool {
        guard let rowModel = model.row(at: row), let column = model.columns.column(at: cell.displayColumn) else { return false }
        let columnRect = table.rect(ofColumn: tableColumn)
        let rowRect = table.rect(ofRow: row)
        let cellRect = NSRect(x: columnRect.minX, y: rowRect.minY, width: columnRect.width, height: rowRect.height)
        if model.configuration.checkboxColumns.contains(column.dataIndex) {
            guard DataGridCheckboxMark.frame(in: cellRect).contains(point) else { return false }
            return toggleCheckbox(rowID: rowModel.id, column: column, displayRow: row)
        }
        let presentation = presenter.presentation(forDataIndex: column.dataIndex)
        guard presentation.accessory != .none, column.dataIndex < rowModel.values.count else { return false }
        let accessory = DataGridCellAccessory.visible(
            for: presentation.kind,
            isEditable: model.configuration.isEditable,
            rawValue: rowModel.values[column.dataIndex].asText
        )
        let frame = accessory.frame(in: cellRect)
        guard !frame.isEmpty, frame.contains(point) else { return false }
        switch accessory {
        case .foreignKey:
            handleForeignKeyArrowClick(at: cell, opensNewTab: event.modifierFlags.contains(.command))
            return true
        case .chevron:
            guard !presenter.visualState(of: rowModel).isDeleted else { return false }
            handleChevronClick(at: cell)
            return true
        case .none:
            return false
        }
    }
}
