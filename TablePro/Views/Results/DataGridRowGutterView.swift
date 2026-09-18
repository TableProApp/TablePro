//
//  DataGridRowGutterView.swift
//  TablePro
//

import AppKit

/// The row-number strip, held at the viewport's leading edge however far the grid is scrolled.
///
/// The `__rowNumber__` column is an ordinary `NSTableColumn` at attached index 0, and clicking it is
/// the only mouse route into whole-row selection: `KeyHandlingTableView.mouseDown` hands a press to
/// `GridSelectionController` for every data column and falls through to `super.mouseDown` only
/// outside one. So scrolling right took the column off screen and took whole-row selection with it,
/// with no keyboard route either (#2664).
///
/// `NSScrollView.addFloatingSubview(_:for:)` is AppKit's own answer, the one it uses for floating
/// group rows. Measured on a real `NSTableView`: for `.horizontal` the view holds window x at the
/// leading edge across every horizontal offset, still moves in y with vertical scroll so the numbers
/// stay level with their rows, and hit-tests normally. AppKit reparents it into a private container
/// under the clip view, so it is not in `NSTableView.subviews` and costs nothing on a wide result,
/// which is the whole point of the drawn-cell grid (#2381). It is document-tall, and measured, its
/// `visibleRect` stays viewport-sized at every offset and it never takes a layer, so drawing is
/// bounded by the viewport rather than by the row count.
///
/// The column stays attached underneath. It reserves the leading width, keeps every column-index
/// computation in the grid working untouched, and keeps mounting the one cell view the grid still
/// mounts, which is the row number's only `AXCell` and the tooltip host for the reason a reorder is
/// unavailable. This view draws over it, so the two must agree on the number they show.
@MainActor
final class DataGridRowGutterView: NSView {
    weak var coordinator: TableViewCoordinator?

    /// Where a Shift-extend measures from. AppKit keeps its own anchor for the row selection it
    /// owns, and does not expose it, so the strip keeps the one its own clicks establish.
    private var selectionAnchorRow: Int?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tableView: KeyHandlingTableView? { coordinator?.tableView as? KeyHandlingTableView }

    /// Held so a second `observeTableGeometry()` replaces rather than stacks, and so the mount that
    /// registered it can take it off again.
    ///
    /// It has to be taken off explicitly. `NotificationCenter` does NOT drop a block observer when
    /// its token is deallocated: measured, a token that is never stored still fires, and one that is
    /// stored and then released still fires. Only the `object:` parameter is held weakly. This
    /// comment used to claim the opposite, which is why the gutter kept a registration per grid
    /// mount for the life of the process. (#2667)
    private var frameObserver: (any NSObjectProtocol)?

    /// Taken off with the mount that made it, beside the coordinator's own observers.
    var hasTableGeometryObserver: Bool { frameObserver != nil }

    func detachTableGeometryObserver() {
        guard let frameObserver else { return }
        NotificationCenter.default.removeObserver(frameObserver)
        self.frameObserver = nil
    }

    /// Follows the table view's own height.
    ///
    /// `NSTableView` resizes its frame to its content, and every path that changes the row count
    /// does it: `reloadData`, `insertRows`, `removeRows`, and a row-height settings change. The
    /// strip is not a subview of the table, so no autoresizing mask reaches it, and the geometry
    /// sync it does get runs from `updateCache()`, which is *before* the reload. Left on that alone
    /// the strip keeps the height the table had when it was empty, and the numbers stop as soon as
    /// the reader scrolls past it. Observing the frame is the one hook that sees all of them.
    func observeTableGeometry() {
        guard let tableView else { return }
        frameObserver.map(NotificationCenter.default.removeObserver)
        tableView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: tableView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeGeometry() }
        }
        synchronizeGeometry()
    }

    // MARK: - Geometry

    /// The span the grid gives the attached column, its intercell spacing included, which is what the
    /// strip has to cover. Zero when row numbers are off, which is what hides the strip.
    ///
    /// Not `column.width`: `rect(ofColumn:)` is a point wider, and the grid's separator stands on that
    /// point. A strip one point short drew its edge beside the grid's line instead of on it, and the
    /// two translucent lines read as one rule twice as thick as every other.
    static func width(of tableView: NSTableView) -> CGFloat {
        let index = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        guard index >= 0, !tableView.tableColumns[index].isHidden else { return 0 }
        return tableView.rect(ofColumn: index).width
    }

    /// Re-reads the width and height from the table. The width moves when the row count crosses a
    /// digit boundary and when the Data Grid Font changes; the height moves with the row count.
    func synchronizeGeometry() {
        guard let tableView else { return }
        let width = Self.width(of: tableView)
        let height = max(tableView.bounds.height, superview?.bounds.height ?? 0)
        isHidden = width <= 0
        /// The same help tag the mounted row-number cell carries. The strip is the handle a reorder
        /// drag starts from once the column has scrolled away, so the reason it cannot run has to be
        /// reachable here too.
        toolTip = coordinator?.rowReorder.unavailableReason
        guard frame.size != NSSize(width: width, height: height) else { return }
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
    }

    // MARK: - Drawing

    /// The grid's leading strip as it stands at scroll offset zero, pinned, over the strip's whole
    /// height: each row's background and number, the stripes the grid continues past the last row,
    /// and the separator at the first data column's leading edge.
    ///
    /// Opaque everywhere, because the columns scroll underneath it, past the last row included. That
    /// area matches only because the grid paints its own background there,
    /// `DataGridBodyChrome.drawTableBackground(in:of:)`, with the same stripe this strip paints.
    override func draw(_ dirtyRect: NSRect) {
        guard let tableView, let coordinator else { return }
        let rowNumberColumn = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        guard rowNumberColumn >= 0 else { return }

        /// The same rule the header uses. An identity check on the first responder is not it: while
        /// a cell is being edited the responder is a descendant field editor, and the row and the
        /// header both stay emphasized, so the strip would turn grey on its own.
        let emphasized = SortableHeaderEmphasis.isEmphasized(
            tableViewHoldsFocus: SortableHeaderEmphasis.holdsFocus(tableView: tableView, in: tableView.window),
            isKeyWindow: tableView.window?.isKeyWindow ?? false
        )
        let font = ThemeEngine.shared.dataGridFonts.rowNumber
        let pageOffset = coordinator.paginationOffsetProvider()

        for band in DataGridBodyChrome.rowBands(in: dirtyRect, of: self, tableView: tableView) {
            let stripRect = NSRect(x: 0, y: band.rect.minY, width: bounds.width, height: band.rect.height)
            guard stripRect.intersects(dirtyRect) else { continue }

            let isSelected = band.isTableRow && tableView.selectedRowIndexes.contains(band.row)
            let state = band.isTableRow ? coordinator.visualState(for: band.row) : .empty
            DataGridBodyChrome.fill(
                stripRect,
                with: rowLayers(row: band.row, isSelected: isSelected, emphasized: emphasized, state: state, tableView: tableView),
                over: tableView.backgroundColor
            )
            guard band.isTableRow else { continue }
            let cellFrame = tableView.frameOfCell(atColumn: rowNumberColumn, row: band.row)
            drawNumber(
                band.row + pageOffset + 1,
                in: NSRect(x: cellFrame.minX, y: stripRect.minY, width: cellFrame.width, height: stripRect.height),
                font: font,
                color: numberColor(isSelected: isSelected, emphasized: emphasized, state: state, coordinator: coordinator)
            )
        }

        drawColumnSeparator(in: dirtyRect, tableView: tableView, coordinator: coordinator)
    }

    /// What the row under the strip paints, in its order, for `DataGridBodyChrome.fill` to blend over
    /// the table's background: `NSTableRowView`'s stripe, then either the selection a `.plain` table
    /// with the regular highlight draws, or the tint `DataGridRowView` gives an unselected row. A
    /// band past the last row has the stripe alone.
    private func rowLayers(
        row: Int,
        isSelected: Bool,
        emphasized: Bool,
        state: RowVisualState,
        tableView: NSTableView
    ) -> [NSColor] {
        var layers: [NSColor] = []
        if let stripe = DataGridBodyChrome.stripeColor(forRow: row, of: tableView) {
            layers.append(stripe)
        }
        if isSelected {
            layers.append(emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
        } else if let tint = state.tint {
            layers.append(tint)
        }
        return layers
    }

    private func numberColor(
        isSelected: Bool,
        emphasized: Bool,
        state: RowVisualState,
        coordinator: TableViewCoordinator
    ) -> NSColor {
        if isSelected, emphasized { return .alternateSelectedControlTextColor }
        return coordinator.cellRegistry.rowNumberColor(for: state)
    }

    /// Right-aligned inside the cell frame AppKit gives the mounted row-number cell, with the insets
    /// that cell uses, so the two renderings land on the same pixels at scroll offset zero.
    private func drawNumber(_ number: Int, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        let inset = DataGridMetrics.cellHorizontalInset
        let origin = NSPoint(
            x: max(rect.minX + inset, rect.maxX - inset - size.width),
            y: rect.midY - size.height / 2
        )
        text.draw(at: origin, withAttributes: attributes)
    }

    /// The first data column's leading separator where it stands at scroll offset zero, which is the
    /// strip's own trailing edge.
    ///
    /// Drawn by `DataGridBodyChrome` over the grid's unscrolled leading strip rather than from a
    /// width of this view's own, so at offset zero it is the very line the row beneath draws, on the
    /// same pixel, and the opaque strip leaves exactly one of them showing.
    private func drawColumnSeparator(
        in rect: NSRect,
        tableView: NSTableView,
        coordinator: TableViewCoordinator
    ) {
        guard !rect.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let tableOriginY = convert(NSPoint.zero, from: tableView).y
        let unscrolledStrip = NSRect(x: 0, y: rect.minY - tableOriginY, width: bounds.width, height: rect.height)
        context.saveGState()
        context.translateBy(x: 0, y: tableOriginY)
        DataGridBodyChrome.drawColumnSeparators(
            in: unscrolledStrip,
            of: tableView,
            tableView: tableView,
            presentsColumn: { coordinator.presentsColumn(atTableColumnIndex: $0) }
        )
        context.restoreGState()
    }

    // MARK: - Selection

    override func mouseDown(with event: NSEvent) {
        guard let tableView, let coordinator else { return }
        let row = row(at: event)
        guard row >= 0 else { return }

        tableView.window?.makeFirstResponder(tableView)

        /// The same reset the attached column's click performs, so the two routes leave the grid in
        /// one state: a whole-row selection owns the grid, and no cell cursor survives it.
        coordinator.selectionController.clear()
        tableView.focusedRow = -1
        tableView.focusedColumn = -1

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        applySelection(row: row, modifiers: modifiers, tableView: tableView)

        guard event.clickCount == 1 else { return }
        trackDrag(from: row, modifiers: modifiers, tableView: tableView, coordinator: coordinator, event: event)
    }

    private func applySelection(row: Int, modifiers: NSEvent.ModifierFlags, tableView: NSTableView) {
        if modifiers.contains(.command) {
            var rows = tableView.selectedRowIndexes
            if rows.contains(row) {
                rows.remove(row)
            } else {
                rows.insert(row)
            }
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            selectionAnchorRow = row
            return
        }
        if modifiers.contains(.shift), let anchor = extendAnchor(in: tableView) {
            tableView.selectRowIndexes(IndexSet(integersIn: min(anchor, row)...max(anchor, row)), byExtendingSelection: false)
            selectionAnchorRow = anchor
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectionAnchorRow = row
    }

    /// Extends the selection while the button is held, and hands over to a reorder drag once the
    /// pointer leaves the row it started on and the grid offers reordering.
    ///
    /// The strip runs its own tracking loop for the same reason `KeyHandlingTableView.trackDrag`
    /// does: `NSTableView`'s own loop is unreachable from here, because this view is not the table.
    private func trackDrag(
        from origin: Int,
        modifiers: NSEvent.ModifierFlags,
        tableView: KeyHandlingTableView,
        coordinator: TableViewCoordinator,
        event: NSEvent
    ) {
        guard let window = tableView.window else { return }
        let canReorder = coordinator.rowReorder.isEnabled && !modifiers.contains(.command)
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        while let next = window.nextEvent(matching: mask) {
            if next.type == .leftMouseUp { return }
            let row = self.row(at: next)
            guard row >= 0 else { continue }
            if canReorder, row != origin {
                beginReorderDrag(from: origin, tableView: tableView, event: next)
                return
            }
            tableView.autoscroll(with: next)
            guard row != origin || tableView.selectedRowIndexes.count != 1 else { continue }
            tableView.selectRowIndexes(
                IndexSet(integersIn: min(origin, row)...max(origin, row)),
                byExtendingSelection: false
            )
        }
    }

    /// Starts the drag `NSTableView` would have started from the attached column.
    ///
    /// The session's source has to be the table view, not this strip: `validateDrop` refuses any
    /// session whose `draggingSource` is not the table it is dropping into, so a strip-sourced drag
    /// would lift the row, open the gap and move nothing.
    private func beginReorderDrag(from row: Int, tableView: KeyHandlingTableView, event: NSEvent) {
        guard let source = tableView.dataSource,
              let writer = source.tableView?(tableView, pasteboardWriterForRow: row) else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let rowRect = convert(tableView.rect(ofRow: row), from: tableView)
        item.setDraggingFrame(NSRect(x: 0, y: rowRect.minY, width: bounds.width, height: rowRect.height), contents: nil)
        tableView.beginDraggingSession(with: [item], event: event, source: tableView)
    }

    // MARK: - Context menu

    /// The row menu the attached column produces: the click resolves no data column, so the copy
    /// item targets the whole row and the cell-only entries stay out.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tableView, let coordinator else { return nil }
        let row = row(at: event)
        guard row >= 0, row < tableView.numberOfRows else { return nil }

        if !tableView.selectedRowIndexes.contains(row) {
            coordinator.selectionController.clear()
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectionAnchorRow = row
        }
        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView else {
            return nil
        }
        return rowView.contextMenu(target: .row)
    }

    /// Where a Shift-extend measures from.
    ///
    /// The remembered anchor is only believed while it is still in range and still selected. A page
    /// load, a new result or a selection made outside the strip all replace the table's selection
    /// without telling this view, and an anchor that outlives one of those extends from a row in a
    /// result that is gone, or past the end of the new one.
    private func extendAnchor(in tableView: NSTableView) -> Int? {
        if let anchor = selectionAnchorRow,
           anchor >= 0, anchor < tableView.numberOfRows,
           tableView.selectedRowIndexes.contains(anchor) {
            return anchor
        }
        selectionAnchorRow = nil
        return tableView.selectedRowIndexes.first
    }

    private func row(at event: NSEvent) -> Int {
        row(atLocalPoint: convert(event.locationInWindow, from: nil))
    }

    private func row(atLocalPoint point: NSPoint) -> Int {
        guard let tableView else { return -1 }
        return tableView.row(at: convert(point, to: tableView))
    }

    // MARK: - Hit testing

    /// Only the rows take a press. Past the last row the strip still paints the grid's stripes, but a
    /// click there belongs to the grid: a double click adds a row and a single click clears the
    /// selection, both of which the strip used to swallow.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return row(atLocalPoint: convert(point, from: superview)) >= 0 ? hit : nil
    }

    // MARK: - Accessibility

    /// The strip is drawn chrome and has no place in the accessibility tree, so AppKit's own hit test
    /// stopped at the nearest element above it, the scroll area, and a pointer over a row's number
    /// found no row at all. Measured, AppKit does consult this override for the floating view. The
    /// strip answers with what it shows: the row's mounted row-number cell view, which is the element
    /// `NSTableView` publishes as that row's cell, while the column is in the viewport; the row once
    /// it is not. `NSTableView` keeps that cell mounted at the column's own position however far the
    /// grid scrolls, measured, so handing it over then would point a client at a frame hundreds of
    /// points off screen. Below the last row, the grid.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let tableView, let window else { return super.accessibilityHitTest(point) }
        let row = row(atLocalPoint: convert(window.convertPoint(fromScreen: point), from: nil))
        let column = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        guard row >= 0, column >= 0 else { return tableView.accessibilityHitTest(point) }
        if tableView.visibleRect.intersects(tableView.rect(ofColumn: column)),
           let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) {
            return cell
        }
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
            return rowView
        }
        return tableView.accessibilityHitTest(point)
    }
}
