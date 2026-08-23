import AppKit

final class KeyHandlingTableView: NSTableView {
    weak var coordinator: TableViewCoordinator?
    weak var selectionOverlay: GridSelectionOverlay?

    private var isRaisingOverlay = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard coordinator?.tabType == .table, let window,
              let mainCoordinator = (coordinator?.delegate as? DataTabGridDelegate)?.coordinator,
              mainCoordinator.consumePendingGridFocus() else { return }
        window.makeFirstResponder(self)
    }

    /// Continues the column separators past the last row.
    ///
    /// A row view covers whatever the table view drew beneath it, so this reaches only the area no
    /// row occupies, which is exactly the area the rows cannot draw. See `DataGridBodyChrome`.
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard let coordinator else { return }
        let lastRowBottom = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : bounds.minY
        let belowRows = clipRect.intersection(
            NSRect(x: clipRect.minX, y: lastRowBottom, width: clipRect.width, height: bounds.height)
        )
        guard !belowRows.isEmpty else { return }
        DataGridBodyChrome.drawColumnSeparators(
            in: belowRows,
            of: self,
            tableView: self,
            presentsColumn: { coordinator.presentsColumn(atTableColumnIndex: $0) }
        )
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard !isRaisingOverlay else { return }
        isRaisingOverlay = true
        defer { isRaisingOverlay = false }
        raiseSelectionOverlayIfNeeded(subview: subview)
        raiseOverlayIfNeeded(coordinator?.overlayEditor, subview: subview)
        raiseOverlayIfNeeded(coordinator?.overlayViewer, subview: subview)
    }

    private func raiseSelectionOverlayIfNeeded(subview: NSView) {
        guard let selectionOverlay,
              selectionOverlay.superview === self,
              subview !== selectionOverlay,
              subviews.last !== selectionOverlay else { return }
        addSubview(selectionOverlay)
    }

    private func raiseOverlayIfNeeded(_ overlay: CellOverlayBase?, subview: NSView) {
        guard let overlay,
              overlay.isActive,
              let container = overlay.containerView,
              container !== subview,
              container.superview === self,
              subviews.last !== container else { return }
        overlay.raiseToFront()
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
        coordinator?.redrawCells(rows: validRows, tableColumnIndexes: validColumns)
    }

    var focusedRow: Int {
        get { selection.focusedRow }
        set { selection.focusedRow = newValue }
    }

    var focusedColumn: Int {
        get { selection.focusedColumn }
        set { selection.focusedColumn = newValue }
    }

    private var gridSelection: GridSelectionController? { coordinator?.selectionController }

    private func withProgrammaticRowSelection(_ work: () -> Void) {
        let coordinator = coordinator
        let wasApplying = coordinator?.isApplyingProgrammaticRowSelection ?? false
        coordinator?.isApplyingProgrammaticRowSelection = true
        work()
        coordinator?.isApplyingProgrammaticRowSelection = wasApplying
    }

    private func totalRows() -> Int { numberOfRows }

    private func totalDataColumns() -> Int {
        guard let schema = coordinator?.identitySchema else { return 0 }
        return schema.totalDataColumns
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

        guard clickedRow >= 0,
              clickedColumn >= 0,
              clickedColumn < numberOfColumns else {
            gridSelection?.clear()
            super.mouseDown(with: event)
            return
        }

        let isDataColumn = presentsDataColumn(at: clickedColumn)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.clickCount >= 2 {
            super.mouseDown(with: event)
            return
        }

        guard isDataColumn,
              let schema = coordinator?.identitySchema,
              let dataColumn = DataGridView.dataColumnIndex(for: clickedColumn, in: self, schema: schema) else {
            gridSelection?.clear()
            super.mouseDown(with: event)
            if !isDataColumn {
                focusedRow = -1
                focusedColumn = -1
            }
            return
        }

        let alreadyFocusedHere = clickedRow == focusedRow && clickedColumn == focusedColumn
        let coord = GridCoord(row: clickedRow, column: dataColumn)
        guard let controller = gridSelection else {
            super.mouseDown(with: event)
            return
        }

        let disposition = controller.beginDrag(at: coord, modifiers: modifiers)
        switch disposition {
        case .replaceFocus(let activeCoord):
            withProgrammaticRowSelection {
                selectRowIndexes(IndexSet(integer: activeCoord.row), byExtendingSelection: false)
            }
            focusedRow = activeCoord.row
            focusedColumn = coordinator?.tableColumnIndex(for: activeCoord.column) ?? clickedColumn
        case .clearFocus:
            deselectAll(nil)
            focusedRow = -1
            focusedColumn = -1
        case .clickThrough:
            super.mouseDown(with: event)
        }

        trackDrag(initial: coord, schema: schema)

        if modifiers.isEmpty,
           alreadyFocusedHere,
           selectedRowIndexes.count == 1,
           coordinator?.canStartInlineEdit(row: clickedRow, columnIndex: dataColumn) == true {
            coordinator?.handleCellInteraction(
                row: clickedRow,
                tableColumn: clickedColumn,
                columnIndex: dataColumn,
                tableView: self
            )
        }
    }

    private func trackDrag(initial: GridCoord, schema: ColumnIdentitySchema) {
        guard let window, let controller = gridSelection else { return }
        var dragged = false
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let event = window.nextEvent(matching: mask) {
            if event.type == .leftMouseUp {
                controller.endDrag(dragged: dragged, originalCoord: initial)
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            autoscroll(with: event)
            let rowIdx = clampRow(row(at: point))
            let columnIdx = clampDataColumn(column(at: point), schema: schema)
            guard rowIdx >= 0, columnIdx >= 0 else { continue }
            let coord = GridCoord(row: rowIdx, column: columnIdx)
            if coord != initial { dragged = true }
            controller.continueDrag(to: coord)
        }
    }

    private func clampRow(_ value: Int) -> Int {
        guard numberOfRows > 0 else { return -1 }
        if value < 0 { return 0 }
        if value >= numberOfRows { return numberOfRows - 1 }
        return value
    }

    private func clampDataColumn(_ value: Int, schema: ColumnIdentitySchema) -> Int {
        let firstData = firstVisibleDataColumn()
        let candidate = value < firstData ? firstData : value
        guard candidate >= 0, candidate < numberOfColumns else { return -1 }
        return DataGridView.dataColumnIndex(for: candidate, in: self, schema: schema) ?? -1
    }

    @objc func delete(_ sender: Any?) {
        guard let coordinator, coordinator.isEditable else { return }
        let indices = coordinator.currentRowSelection()
        guard !indices.isEmpty else { return }
        coordinator.delegate?.dataGridDeleteRows(indices)
    }

    @objc func copy(_ sender: Any?) {
        if let controller = gridSelection, !controller.isEmpty {
            coordinator?.copyGridSelection(controller.selection)
            return
        }
        if let cell = focusedDataCell() {
            coordinator?.copyCellValue(at: cell.row, columnIndex: cell.columnIndex)
            return
        }
        coordinator?.delegate?.dataGridCopyRows(Set(selectedRowIndexes))
    }

    @objc func copyRowsAsTSV(_ sender: Any?) {
        guard let coordinator else { return }
        coordinator.delegate?.dataGridCopyRows(coordinator.currentRowSelection())
    }

    @objc override func selectAll(_ sender: Any?) {
        let totalRows = totalRows()
        let totalColumns = totalDataColumns()
        guard totalRows > 0, totalColumns > 0 else {
            super.selectAll(sender)
            return
        }
        gridSelection?.selectAll(totalRows: totalRows, totalColumns: totalColumns)
        selectRowIndexes(IndexSet(integersIn: 0..<totalRows), byExtendingSelection: false)
    }

    private func focusedDataCell() -> (row: Int, columnIndex: Int)? {
        guard selectedRowIndexes.count == 1,
              focusedRow >= 0,
              presentsDataColumn(at: focusedColumn),
              let schema = coordinator?.identitySchema,
              let dataColumn = DataGridView.dataColumnIndex(for: focusedColumn, in: self, schema: schema) else {
            return nil
        }
        return (focusedRow, dataColumn)
    }

    @objc func paste(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        if let anchor = pasteAnchorCell(),
           coordinator?.pasteCellsFromClipboard(anchorRow: anchor.row, anchorColumn: anchor.column) == true {
            return
        }
        coordinator?.delegate?.dataGridPasteRows()
    }

    /// The cell a paste would land in. Deliberately looser than `focusedDataCell()`, which also
    /// requires a single selected row: a paste anchors on the focused cell alone.
    private func pasteAnchorCell() -> (row: Int, column: Int)? {
        guard focusedRow >= 0,
              presentsDataColumn(at: focusedColumn),
              let schema = coordinator?.identitySchema,
              let dataCol = DataGridView.dataColumnIndex(for: focusedColumn, in: self, schema: schema) else {
            return nil
        }
        return (focusedRow, dataCol)
    }

    /// Both routes `paste(_:)` can take, asked before the menu item is enabled. The item used to be
    /// enabled whenever the grid was editable and had a delegate, which lit it over query-result
    /// tabs where `pasteRows()` returns at its first guard. AppKit gives a disabled item its key
    /// equivalent anyway, so an enabled-but-dead item swallows Command+V in silence.
    private var canPaste: Bool {
        guard let coordinator, coordinator.isEditable else { return false }
        if coordinator.delegate?.dataGridCanPasteRows() == true { return true }
        guard let anchor = pasteAnchorCell() else { return false }
        return coordinator.canPasteCellsFromClipboard(anchorRow: anchor.row, anchorColumn: anchor.column)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(delete(_:)), #selector(deleteBackward(_:)):
            let hasGridSelection = gridSelection?.isEmpty == false
            return coordinator?.isEditable == true && (hasGridSelection || !selectedRowIndexes.isEmpty)
        case #selector(copy(_:)):
            let hasGridSelection = gridSelection?.isEmpty == false
            return hasGridSelection || !selectedRowIndexes.isEmpty
        case #selector(copyRowsAsTSV(_:)):
            let hasGridSelection = gridSelection?.isEmpty == false
            return hasGridSelection || !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return canPaste
        case #selector(insertNewline(_:)):
            return selectedRow >= 0 && presentsDataColumn(at: focusedColumn)
        case #selector(selectAll(_:)):
            return numberOfRows > 0
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let key = KeyCode(rawValue: event.keyCode) else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let row = selectedRow

        switch key {
        case .leftArrow:
            handleArrow(.left, modifiers: modifiers, currentRow: row, event: event)
            return
        case .rightArrow:
            handleArrow(.right, modifiers: modifiers, currentRow: row, event: event)
            return
        case .upArrow:
            handleArrow(.up, modifiers: modifiers, currentRow: row, event: event)
            return
        case .downArrow:
            handleArrow(.down, modifiers: modifiers, currentRow: row, event: event)
            return
        case .home, .end, .pageUp, .pageDown:
            super.keyDown(with: event)
            return
        case .delete, .forwardDelete:
            if modifiers.isEmpty || matchesDeleteShortcut(event) {
                deleteSelectedRowsIfPossible()
                return
            }
        default:
            break
        }

        if let fkCombo = AppSettingsManager.shared.keyboard.shortcut(for: .previewFKReference),
           !fkCombo.isCleared,
           fkCombo.matches(event),
           selectedRow >= 0,
           presentsDataColumn(at: focusedColumn),
           let schema = coordinator?.identitySchema,
           let columnIndex = DataGridView.dataColumnIndex(for: focusedColumn, in: self, schema: schema) {
            coordinator?.toggleForeignKeyPreview(
                tableView: self,
                row: selectedRow,
                column: focusedColumn,
                columnIndex: columnIndex
            )
            return
        }

        interpretKeyEvents([event])
    }

    private func matchesDeleteShortcut(_ event: NSEvent) -> Bool {
        guard let combo = AppSettingsManager.shared.keyboard.shortcut(for: .delete), !combo.isCleared else {
            return false
        }
        return combo.matches(event)
    }

    private func handleArrow(_ direction: GridSelectionController.Direction, modifiers: NSEvent.ModifierFlags, currentRow: Int, event: NSEvent) {
        if modifiers.contains(.shift) {
            if extendGridSelection(direction: direction, jumpToEdge: modifiers.contains(.command)) {
                return
            }
            super.keyDown(with: event)
            return
        }
        gridSelection?.clear()
        switch direction {
        case .left: handleLeftArrow(currentRow: currentRow)
        case .right: handleRightArrow(currentRow: currentRow)
        case .up, .down: super.keyDown(with: event)
        }
    }

    private func extendGridSelection(direction: GridSelectionController.Direction, jumpToEdge: Bool) -> Bool {
        guard let controller = gridSelection else { return false }
        let seed = controller.isEmpty ? focusedGridCoord() : nil
        guard !controller.isEmpty || seed != nil else { return false }
        controller.extendActiveCell(
            from: seed,
            direction: direction,
            jumpToEdge: jumpToEdge,
            totalRows: totalRows(),
            totalColumns: totalDataColumns()
        )
        return true
    }

    private func focusedGridCoord() -> GridCoord? {
        guard let cell = focusedDataCell() else { return nil }
        return GridCoord(row: cell.row, column: cell.columnIndex)
    }

    @objc override func insertNewline(_ sender: Any?) {
        let row = selectedRow
        guard row >= 0,
              presentsDataColumn(at: focusedColumn),
              let schema = coordinator?.identitySchema,
              let columnIndex = DataGridView.dataColumnIndex(for: focusedColumn, in: self, schema: schema),
              let coordinator else {
            return
        }
        // The cell cursor can sit on a column the window left out, and a cell with no view behind
        // it opens nothing at all. Reaching it first also puts it on screen, where the editor the
        // keystroke is about to open belongs.
        coordinator.scrollColumnToVisible(tableColumnIndex: focusedColumn)
        coordinator.handleCellInteraction(row: row, tableColumn: focusedColumn, columnIndex: columnIndex, tableView: self)
    }

    @objc override func cancelOperation(_ sender: Any?) {
        guard let controller = gridSelection, !controller.isEmpty else {
            super.cancelOperation(sender)
            return
        }
        controller.clear()
    }

    private func deleteSelectedRowsIfPossible() {
        guard coordinator?.isEditable == true else { return }
        guard gridSelection?.isEmpty == false || !selectedRowIndexes.isEmpty else { return }
        delete(nil)
    }

    private func handleLeftArrow(currentRow: Int) {
        let target = focusedColumn < 0
            ? lastVisibleDataColumn()
            : previousVisibleDataColumn(before: focusedColumn)
        guard presentsDataColumn(at: target) else { return }
        focusedColumn = target
        coordinator?.dismissFKPreviewOnColumnChange()
        if currentRow >= 0 { coordinator?.scrollColumnToVisible(tableColumnIndex: target) }
    }

    private func handleRightArrow(currentRow: Int) {
        let target = presentsDataColumn(at: focusedColumn)
            ? nextVisibleDataColumn(after: focusedColumn)
            : firstVisibleDataColumn()
        guard presentsDataColumn(at: target) else { return }
        focusedColumn = target
        coordinator?.dismissFKPreviewOnColumnChange()
        if currentRow >= 0 { coordinator?.scrollColumnToVisible(tableColumnIndex: target) }
    }

    private func firstVisibleDataColumn() -> Int {
        coordinator?.firstPresentedColumnIndex() ?? -1
    }

    private func lastVisibleDataColumn() -> Int {
        coordinator?.lastPresentedColumnIndex() ?? -1
    }

    private func nextVisibleDataColumn(after current: Int) -> Int {
        coordinator?.nextPresentedColumnIndex(after: current) ?? -1
    }

    private func previousVisibleDataColumn(before current: Int) -> Int {
        coordinator?.previousPresentedColumnIndex(before: current) ?? -1
    }

    /// Whether this position in `tableColumns` holds one of the columns the result presents.
    ///
    /// The row-number column and the window's two spacers are attached columns as well, and one
    /// spacer sits immediately before the first data column, so no fixed position answers this.
    func presentsDataColumn(at index: Int) -> Bool {
        guard index >= 0, index < numberOfColumns else { return false }
        guard let coordinator else { return !tableColumns[index].isHidden }
        return coordinator.presentsColumn(atTableColumnIndex: index)
    }

    /// `NSResponder` declares these two but does not implement them, so calling `super` raises
    /// `doesNotRecognizeSelector`. With no cell cursor to move, Tab has to leave the grid the way
    /// it leaves any other view, or focus is trapped here for the rest of the session.
    /// VoiceOver follows the focused element, and a table view reports itself rather than the
    /// cell the grid's own cursor is on, so the cursor was invisible to it. The selected-cells
    /// override is clamped to the visible rows: AppKit will happily ask for every cell in a
    /// million-row selection otherwise.
    /// The cursor moved, so assistive technology is told to re-read where focus now is.
    ///
    /// A cell is drawn rather than mounted, so the element comes from the row's own accessibility
    /// children rather than from a cell view.
    internal func postCellCursorMoved() {
        guard selectedRow >= 0, presentsDataColumn(at: focusedColumn) else { return }
        guard let element = accessibilityCellElement(row: selectedRow, tableColumnIndex: focusedColumn) else { return }
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
    }

    /// What stands for one cell: the view mounted for accessibility, which exists only once a
    /// client has asked the grid anything. Asking marks accessibility active, so the first such
    /// question is also what brings the views into being.
    private func accessibilityCellElement(row: Int, tableColumnIndex: Int) -> Any? {
        DataGridAccessibility.markActive()
        return view(atColumn: tableColumnIndex, row: row, makeIfNecessary: false) as? DataGridCellAccessibilityView
    }

    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        accessibilityCellElement(row: row, tableColumnIndex: column) ?? super.accessibilityCell(forColumn: column, row: row)
    }

    /// Anything walking the tree reaches here, which is the grid's signal that a client is attached.
    override func accessibilityChildren() -> [Any]? {
        DataGridAccessibility.markActive()
        return super.accessibilityChildren()
    }

    /// `NSTableView` answers an accessibility hit test itself and stops at a cell, so a point inside
    /// a row but outside every column resolved to the table rather than to the row: an ancestor
    /// rather than a descendant, which a client reads as the row not being reachable at that point.
    /// A result narrower than the grid leaves most of each row in exactly that state.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        DataGridAccessibility.markActive()
        guard let window else { return super.accessibilityHitTest(point) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let index = row(at: local)
        guard index >= 0, let rowView = rowView(atRow: index, makeIfNecessary: false) else {
            return super.accessibilityHitTest(point)
        }
        return rowView.accessibilityHitTest(point) ?? rowView
    }

    override func accessibilitySelectedCells() -> [Any]? {
        guard let controller = gridSelection, !controller.isEmpty else {
            return super.accessibilitySelectedCells()
        }
        let visible = rows(in: visibleRect)
        guard visible.length > 0 else { return [] }
        var cells: [Any] = []
        for rectangle in controller.selection.rectangles {
            for row in rectangle.rows where NSLocationInRange(row, visible) {
                for column in rectangle.columns {
                    guard let position = coordinator?.tableColumnIndex(for: column),
                          let element = accessibilityCellElement(row: row, tableColumnIndex: position) else { continue }
                    cells.append(element)
                }
            }
        }
        return cells
    }

    override func insertTab(_ sender: Any?) {
        guard !moveFocusToNextCell() else { return }
        window?.selectKeyView(following: self)
    }

    override func insertBacktab(_ sender: Any?) {
        guard !moveFocusToPreviousCell() else { return }
        window?.selectKeyView(preceding: self)
    }

    private func moveFocusToNextCell() -> Bool {
        let row = selectedRow
        guard row >= 0, presentsDataColumn(at: focusedColumn) else { return false }

        var nextColumn = nextVisibleDataColumn(after: focusedColumn)
        var nextRow = row
        if nextColumn < 0 {
            let wrapped = firstVisibleDataColumn()
            guard wrapped >= 0, row + 1 < numberOfRows else { return true }
            nextColumn = wrapped
            nextRow = row + 1
        }
        focusCell(row: nextRow, column: nextColumn)
        return true
    }

    private func moveFocusToPreviousCell() -> Bool {
        let row = selectedRow
        guard row >= 0, presentsDataColumn(at: focusedColumn) else { return false }

        var previousColumn = previousVisibleDataColumn(before: focusedColumn)
        var previousRow = row
        if previousColumn < 0 {
            let wrapped = lastVisibleDataColumn()
            guard wrapped >= 0, row > 0 else { return true }
            previousColumn = wrapped
            previousRow = row - 1
        }
        focusCell(row: previousRow, column: previousColumn)
        return true
    }

    private func focusCell(row: Int, column: Int) {
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        focusedRow = row
        focusedColumn = column
        scrollRowToVisible(row)
        coordinator?.scrollColumnToVisible(tableColumnIndex: column)
        postCellCursorMoved()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0, clickIsInsideSelection(row: clickedRow, point: point) {
            window?.makeFirstResponder(self)
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        super.rightMouseDown(with: event)
    }

    private func clickIsInsideSelection(row clickedRow: Int, point: NSPoint) -> Bool {
        if selectedRowIndexes.contains(clickedRow) { return true }
        guard let controller = gridSelection, !controller.isEmpty else { return false }
        let clickedColumn = column(at: point)
        guard clickedColumn >= 0,
              let schema = coordinator?.identitySchema,
              let dataColumn = DataGridView.dataColumnIndex(for: clickedColumn, in: self, schema: schema) else {
            return false
        }
        return controller.selection.contains(row: clickedRow, column: dataColumn)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)

        if clickedRow >= 0, let rowView = rowView(atRow: clickedRow, makeIfNecessary: false) as? DataGridRowView {
            if let schema = coordinator?.identitySchema,
               clickedColumn >= 0,
               let dataColumn = DataGridView.dataColumnIndex(for: clickedColumn, in: self, schema: schema),
               let controller = gridSelection,
               !controller.isEmpty,
               controller.selection.contains(row: clickedRow, column: dataColumn) {
                return rowView.contextMenu(for: event)
            }
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            return rowView.contextMenu(for: event)
        }

        if let menu = coordinator?.delegate?.dataGridEmptySpaceMenu() {
            return menu
        }

        return super.menu(for: event)
    }
}
