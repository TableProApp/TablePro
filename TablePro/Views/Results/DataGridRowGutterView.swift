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

    /// Held so a second `observeTableGeometry()` replaces rather than stacks. It is not removed in
    /// `deinit`: this is a `@MainActor` view and a `deinit` is nonisolated, and since macOS 10.11
    /// `NotificationCenter` drops a block observer whose token is deallocated, so the token dying
    /// with the view is the removal.
    private var frameObserver: (any NSObjectProtocol)?

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

    /// The width the attached column reserves, which is what the strip has to cover. Zero when row
    /// numbers are off, which is what hides the strip.
    static func width(of tableView: NSTableView) -> CGFloat {
        guard let column = tableView.tableColumns.first(where: {
            $0.identifier == ColumnIdentitySchema.rowNumberIdentifier
        }), !column.isHidden else { return 0 }
        return column.width
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

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView, let coordinator else { return }
        let inTableView = convert(dirtyRect, to: tableView)
        let rows = tableView.rows(in: inTableView)
        guard rows.length > 0 else { return }

        let alternates = tableView.usesAlternatingRowBackgroundColors
        /// The same rule the header uses. An identity check on the first responder is not it: while
        /// a cell is being edited the responder is a descendant field editor, and the row and the
        /// header both stay emphasized, so the strip would turn grey on its own.
        let emphasized = SortableHeaderEmphasis.isEmphasized(
            tableViewHoldsFocus: SortableHeaderEmphasis.holdsFocus(tableView: tableView, in: tableView.window),
            isKeyWindow: tableView.window?.isKeyWindow ?? false
        )
        let font = ThemeEngine.shared.dataGridFonts.rowNumber
        let pageOffset = coordinator.paginationOffsetProvider()
        let rowCount = tableView.numberOfRows

        for row in rows.location..<(rows.location + rows.length) {
            guard row >= 0, row < rowCount else { continue }
            let rowRect = convert(tableView.rect(ofRow: row), from: tableView)
            let stripRect = NSRect(x: 0, y: rowRect.minY, width: bounds.width, height: rowRect.height)
            guard stripRect.intersects(dirtyRect) else { continue }

            let isSelected = tableView.selectedRowIndexes.contains(row)
            let state = coordinator.visualState(for: row)
            backgroundColor(row: row, isSelected: isSelected, emphasized: emphasized, alternates: alternates)
                .setFill()
            stripRect.fill()
            if !isSelected, let tint = tint(for: state) {
                tint.setFill()
                stripRect.fill()
            }

            drawNumber(
                row + pageOffset + 1,
                in: stripRect,
                font: font,
                color: numberColor(isSelected: isSelected, emphasized: emphasized, state: state)
            )
        }

        drawTrailingSeparator(in: dirtyRect)
    }

    /// The colours `NSTableRowView` paints for a `.plain` table with the regular selection style,
    /// which is what the row under this strip is showing.
    private func backgroundColor(row: Int, isSelected: Bool, emphasized: Bool, alternates: Bool) -> NSColor {
        if isSelected {
            return emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        }
        let backgrounds = NSColor.alternatingContentBackgroundColors
        guard alternates, backgrounds.count > 1 else { return backgrounds.first ?? .controlBackgroundColor }
        return backgrounds[row % backgrounds.count]
    }

    private func tint(for state: RowVisualState) -> NSColor? {
        if state.isDeleted { return ThemeEngine.shared.colors.dataGrid.deleted }
        if state.isInserted { return ThemeEngine.shared.colors.dataGrid.inserted }
        return nil
    }

    private func numberColor(isSelected: Bool, emphasized: Bool, state: RowVisualState) -> NSColor {
        if isSelected, emphasized { return .alternateSelectedControlTextColor }
        if state.isDeleted { return ThemeEngine.shared.colors.dataGrid.deletedText }
        return .secondaryLabelColor
    }

    /// Right-aligned inside the same insets the mounted cell uses, so the two renderings line up
    /// exactly where they overlap at scroll offset zero.
    private func drawNumber(_ number: Int, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        let inset = DataGridMetrics.cellHorizontalInset
        let origin = NSPoint(
            x: max(inset, rect.maxX - inset - size.width),
            y: rect.midY - size.height / 2
        )
        text.draw(at: origin, withAttributes: attributes)
    }

    /// The boundary between the strip and the content scrolling under it. The separator
    /// `DataGridBodyChrome` draws stands at the first data column's leading edge in document space,
    /// so it scrolls away and cannot serve as this edge.
    private func drawTrailingSeparator(in dirtyRect: NSRect) {
        let separator = NSRect(
            x: bounds.maxX - DataGridBodyChrome.separatorThickness,
            y: dirtyRect.minY,
            width: DataGridBodyChrome.separatorThickness,
            height: dirtyRect.height
        )
        guard separator.intersects(dirtyRect) else { return }
        (tableView?.gridColor ?? .gridColor).setFill()
        separator.fill()
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
        guard let tableView else { return -1 }
        let point = convert(event.locationInWindow, from: nil)
        return tableView.row(at: convert(point, to: tableView))
    }
}
