//
//  DataGridTableView.swift
//  TablePro
//

import AppKit

// One class for both panes. Behavior comes from NSResponder actions the standard key bindings produce, never key codes.
@MainActor
final class DataGridTableView: NSTableView {
    weak var controller: DataGridViewController?
    var paneKind: DataGridPane.Kind = .main

    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    // The main table is the grid's one first responder; a press in the frozen pane hands focus to it.
    override var acceptsFirstResponder: Bool {
        paneKind == .main
    }

    // MARK: - Drawing

    override func drawBackground(inClipRect clipRect: NSRect) {
        let scope = controller?.model.themeScope ?? .live
        DataGridBodyChrome.drawTableBackground(in: clipRect, of: self, scope: scope)
        let lastRowBottom = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : bounds.minY
        let belowRows = clipRect.intersection(NSRect(x: clipRect.minX, y: lastRowBottom, width: clipRect.width, height: bounds.height))
        guard !belowRows.isEmpty else { return }
        DataGridBodyChrome.drawColumnSeparators(in: belowRows, of: self, tableView: self)
        if paneKind == .frozen {
            controller?.drawFrozenPaneEdge(in: belowRows, of: self)
        }
    }

    // AppKit sizes the table to its columns; widening the proposed frame keeps the header and rows over the trailing space.
    override func setFrameSize(_ newSize: NSSize) {
        guard paneKind == .main, let last = tableColumns.indices.last else {
            super.setFrameSize(newSize)
            return
        }
        let trailingExtent = rect(ofColumn: last).maxX + DataGridMetrics.trailingSpace
        super.setFrameSize(NSSize(width: max(newSize.width, trailingExtent), height: newSize.height))
    }

    // AppKit reorders tableColumns on each pass of a header drag but posts columnDidMove only at mouse-up.
    override func moveColumn(_ oldIndex: Int, toColumn newIndex: Int) {
        super.moveColumn(oldIndex, toColumn: newIndex)
        controller?.tableDidMoveColumn(self)
    }

    // A revealed column must never park under the frozen pane, so the rect widens leftward by its width.
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard paneKind == .main, let controller else { return super.scrollToVisible(rect) }
        let widened = controller.revealRect(for: rect, in: self)
        guard controller.model.configuration.fitsRows else { return super.scrollToVisible(widened) }
        // Only sideways. AppKit calls this itself while the pane resizes, with rects spanning the header, so the page
        // moves only for a reveal the grid starts (`scrollRowToVisible`, `reveal(row:displayColumn:)`).
        let visible = visibleRect
        return super.scrollToVisible(NSRect(x: widened.minX, y: visible.midY, width: widened.width, height: 1))
    }

    // Up, Down and type-select reveal through here; a table that fits its rows has nothing to scroll, so the page moves.
    override func scrollRowToVisible(_ row: Int) {
        guard paneKind == .main, let controller, controller.model.configuration.fitsRows else {
            super.scrollRowToVisible(row)
            return
        }
        guard row >= 0, row < numberOfRows else { return }
        controller.revealOnPage(rect(ofRow: row))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard paneKind == .main, let controller else {
            super.keyDown(with: event)
            return
        }
        if controller.handleGridKey(event) { return }
        if routesThroughKeyBindings(event) {
            interpretKeyEvents([event])
            return
        }
        super.keyDown(with: event)
    }

    // NSTableView.keyDown never calls interpretKeyEvents and leaves these keys unanswered (probe P3).
    private func routesThroughKeyBindings(_ event: NSEvent) -> Bool {
        guard let specialKey = event.specialKey else { return false }
        let modifiers = event.modifierFlags.intersection(Self.chordModifiers)
        switch specialKey {
        case .tab, .backTab:
            // Control-Tab leaves the table through the key view loop.
            return !modifiers.contains(.control)
        case .carriageReturn, .newline, .enter, .delete, .deleteForward, .leftArrow, .rightArrow:
            return true
        case .upArrow, .downArrow:
            return modifiers.contains(.shift) && controller?.selectionIsCellRange == true
        default:
            return false
        }
    }

    override func moveLeft(_ sender: Any?) {
        controller?.moveSelection(.left, extending: false, toEdge: false)
    }

    override func moveRight(_ sender: Any?) {
        controller?.moveSelection(.right, extending: false, toEdge: false)
    }

    override func moveWordLeft(_ sender: Any?) {
        controller?.moveSelection(.left, extending: false, toEdge: false)
    }

    override func moveWordRight(_ sender: Any?) {
        controller?.moveSelection(.right, extending: false, toEdge: false)
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.left, extending: true, toEdge: false)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.right, extending: true, toEdge: false)
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.left, extending: true, toEdge: false)
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.right, extending: true, toEdge: false)
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.up, extending: true, toEdge: false)
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.down, extending: true, toEdge: false)
    }

    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.up, extending: true, toEdge: true)
    }

    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        controller?.moveSelection(.down, extending: true, toEdge: true)
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        controller?.moveToColumnEdge(last: false, extending: false)
    }

    override func moveToEndOfLine(_ sender: Any?) {
        controller?.moveToColumnEdge(last: true, extending: false)
    }

    override func moveToLeftEndOfLine(_ sender: Any?) {
        controller?.moveToColumnEdge(last: false, extending: false)
    }

    override func moveToRightEndOfLine(_ sender: Any?) {
        controller?.moveToColumnEdge(last: true, extending: false)
    }

    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        controller?.moveToColumnEdge(last: false, extending: true)
    }

    override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        controller?.moveToColumnEdge(last: true, extending: true)
    }

    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        controller?.moveToColumnEdge(last: false, extending: true)
    }

    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        controller?.moveToColumnEdge(last: true, extending: true)
    }

    override func insertTab(_ sender: Any?) {
        guard controller?.tabToCell(forward: true) == true else {
            window?.selectKeyView(following: self)
            return
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard controller?.tabToCell(forward: false) == true else {
            window?.selectKeyView(preceding: self)
            return
        }
    }

    override func insertNewline(_ sender: Any?) {
        controller?.beginEditingActiveCell()
    }

    override func cancelOperation(_ sender: Any?) {
        guard controller?.cancelSelection() == true else {
            super.cancelOperation(sender)
            return
        }
    }

    override func deleteBackward(_ sender: Any?) {
        controller?.performDeleteCommand()
    }

    override func deleteForward(_ sender: Any?) {
        controller?.performDeleteCommand()
    }

    override func selectAll(_ sender: Any?) {
        controller?.performSelectAll(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action,
           let enabled = FontSizeZoom.dataGrid.enablement(action, typography: AppSettingsManager.shared.typography) {
            return enabled
        }
        if item.action == #selector(selectAll(_:)) {
            return controller?.validateGridCommand(item) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let controller else {
            super.mouseDown(with: event)
            return
        }
        controller.tableMouseDown(self, with: event)
    }

    // The controller hands a press back here when AppKit's own tracking is wanted, for a row reorder drag.
    func performNativeMouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        guard paneKind == .frozen, let controller else { return false }
        let column = column(at: mouseDownPoint)
        let row = row(at: mouseDownPoint)
        guard column >= 0, column < tableColumns.count, row >= 0,
              tableColumns[column].identifier == DataGridPane.rowNumberIdentifier,
              controller.canDragRows(fromRowNumberAt: row) else { return false }
        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    // MARK: - Accessibility

    override func accessibilityChildren() -> [Any]? {
        guard paneKind == .main else { return [] }
        noteAccessibilityRead()
        return super.accessibilityChildren()
    }

    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        guard paneKind == .main else { return nil }
        noteAccessibilityRead()
        return view(atColumn: column, row: row, makeIfNecessary: false) as? DataGridAccessibilityCellView
            ?? super.accessibilityCell(forColumn: column, row: row)
    }

    // A read prepares every row it walks, off screen ones without a stand-in, and some reach the screen with no scroll.
    private func noteAccessibilityRead() {
        DataGridAccessibility.markActive()
        controller?.scheduleAccessibilityRemount()
    }

    override func accessibilitySelectedCells() -> [Any]? {
        guard paneKind == .main else { return [] }
        return controller?.accessibilitySelectedCells() ?? super.accessibilitySelectedCells()
    }

    // A point inside a row but outside every column resolves to the row, not the table, so the row stays reachable there.
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
}

extension DataGridTableView: ZoomCommandResponding {
    @objc func zoomIn(_ sender: Any?) {
        FontSizeZoom.dataGrid.zoom(by: 1)
    }

    @objc func zoomOut(_ sender: Any?) {
        FontSizeZoom.dataGrid.zoom(by: -1)
    }
}
