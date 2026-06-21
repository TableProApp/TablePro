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

        let column = tableColumns[clickedColumn]
        let isDataColumn = column.identifier != ColumnIdentitySchema.rowNumberIdentifier
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
        let firstData = DataGridView.firstDataTableColumnIndex
        let candidate = value < firstData ? firstData : value
        guard candidate >= 0, candidate < numberOfColumns else { return -1 }
        return DataGridView.dataColumnIndex(for: candidate, in: self, schema: schema) ?? -1
    }

    @objc func delete(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        if let controller = gridSelection, !controller.isEmpty {
            coordinator?.delegate?.dataGridDeleteRows(Set(controller.selection.affectedRows))
            return
        }
        guard !selectedRowIndexes.isEmpty else { return }
        coordinator?.delegate?.dataGridDeleteRows(Set(selectedRowIndexes))
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
        coordinator?.delegate?.dataGridCopyRows(Set(selectedRowIndexes))
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
              DataGridView.isDataTableColumn(focusedColumn),
              let schema = coordinator?.identitySchema,
              let dataColumn = DataGridView.dataColumnIndex(for: focusedColumn, in: self, schema: schema) else {
            return nil
        }
        return (focusedRow, dataColumn)
    }

    @objc func paste(_ sender: Any?) {
        guard coordinator?.isEditable == true else { return }
        if focusedRow >= 0,
           DataGridView.isDataTableColumn(focusedColumn),
           let schema = coordinator?.identitySchema,
           let dataCol = DataGridView.dataColumnIndex(for: focusedColumn, in: self, schema: schema),
           coordinator?.pasteCellsFromClipboard(anchorRow: focusedRow, anchorColumn: dataCol) == true {
            return
        }
        coordinator?.delegate?.dataGridPasteRows()
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
            return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return coordinator?.isEditable == true && coordinator?.delegate != nil
        case #selector(insertNewline(_:)):
            return selectedRow >= 0 && DataGridView.isDataTableColumn(focusedColumn)
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

        if key == .tab {
            if event.modifierFlags.contains(.shift) {
                handleShiftTabKey()
            } else {
                handleTabKey()
            }
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
           DataGridView.isDataTableColumn(focusedColumn),
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
              DataGridView.isDataTableColumn(focusedColumn),
              let schema = coordinator?.identitySchema,
              let columnIndex = DataGridView.dataColumnIndex(for: focusedColumn, in: self, schema: schema),
              let coordinator else {
            return
        }
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
        guard DataGridView.isDataTableColumn(target) else { return }
        focusedColumn = target
        coordinator?.dismissFKPreviewOnColumnChange()
        if currentRow >= 0 { scrollColumnToVisible(target) }
    }

    private func handleRightArrow(currentRow: Int) {
        let target = DataGridView.isDataTableColumn(focusedColumn)
            ? nextVisibleDataColumn(after: focusedColumn)
            : firstVisibleDataColumn()
        guard DataGridView.isDataTableColumn(target) else { return }
        focusedColumn = target
        coordinator?.dismissFKPreviewOnColumnChange()
        if currentRow >= 0 { scrollColumnToVisible(target) }
    }

    private func firstVisibleDataColumn() -> Int {
        for index in DataGridView.firstDataTableColumnIndex..<numberOfColumns where isVisibleDataColumn(at: index) {
            return index
        }
        return -1
    }

    private func lastVisibleDataColumn() -> Int {
        for index in stride(
            from: numberOfColumns - 1,
            through: DataGridView.firstDataTableColumnIndex,
            by: -1
        ) where isVisibleDataColumn(at: index) {
            return index
        }
        return -1
    }

    private func nextVisibleDataColumn(after current: Int) -> Int {
        guard current + 1 < numberOfColumns else { return -1 }
        for index in (current + 1)..<numberOfColumns where isVisibleDataColumn(at: index) {
            return index
        }
        return -1
    }

    private func previousVisibleDataColumn(before current: Int) -> Int {
        guard current > DataGridView.firstDataTableColumnIndex else { return -1 }
        for index in stride(
            from: current - 1,
            through: DataGridView.firstDataTableColumnIndex,
            by: -1
        ) where isVisibleDataColumn(at: index) {
            return index
        }
        return -1
    }

    private func isVisibleDataColumn(at index: Int) -> Bool {
        guard index >= 0, index < numberOfColumns else { return false }
        let column = tableColumns[index]
        return !column.isHidden && column.identifier != ColumnIdentitySchema.rowNumberIdentifier
    }

    private func handleTabKey() {
        let row = selectedRow
        guard row >= 0, DataGridView.isDataTableColumn(focusedColumn) else { return }

        var nextColumn = focusedColumn + 1
        var nextRow = row

        if nextColumn >= numberOfColumns {
            nextColumn = DataGridView.firstDataTableColumnIndex
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
        guard row >= 0, DataGridView.isDataTableColumn(focusedColumn) else { return }

        var prevColumn = focusedColumn - 1
        var prevRow = row

        if !DataGridView.isDataTableColumn(prevColumn) {
            prevColumn = numberOfColumns - 1
            prevRow -= 1
        }
        if prevRow < 0 {
            prevRow = 0
            prevColumn = DataGridView.firstDataTableColumnIndex
        }

        selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
        focusedRow = prevRow
        focusedColumn = prevColumn
        scrollRowToVisible(prevRow)
        scrollColumnToVisible(prevColumn)
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

        if clickedRow >= 0, let rowView = rowView(atRow: clickedRow, makeIfNecessary: false) {
            if let schema = coordinator?.identitySchema,
               clickedColumn >= 0,
               let dataColumn = DataGridView.dataColumnIndex(for: clickedColumn, in: self, schema: schema),
               let controller = gridSelection,
               !controller.isEmpty,
               controller.selection.contains(row: clickedRow, column: dataColumn) {
                return rowView.menu(for: event)
            }
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
