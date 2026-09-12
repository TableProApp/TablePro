import AppKit

@MainActor
final class GridSelectionController {
    enum Direction {
        case up
        case down
        case left
        case right
    }

    private(set) var selection: GridSelection = .empty

    weak var tableView: NSTableView?
    weak var overlay: GridSelectionOverlay?
    weak var coordinator: TableViewCoordinator?

    private var dragOrigin: GridCoord?
    private var dragMode: DragMode = .replace
    private var dragBaseSelection: GridSelection = .empty
    var onSelectionChange: ((GridSelection) -> Void)?

    var isEmpty: Bool { selection.isEmpty }

    private enum DragMode {
        case replace
        case additive
    }

    func update(_ newSelection: GridSelection) {
        guard selection != newSelection else { return }
        let old = selection
        selection = newSelection
        overlay?.selection = newSelection
        let dirty = reloadColumns(for: old, new: newSelection)
        reloadRowsForFill(old: old, new: newSelection, dirtyColumns: dirty)
        postAccessibilityAnnouncement(for: newSelection)
        onSelectionChange?(newSelection)
    }

    private func postAccessibilityAnnouncement(for newSelection: GridSelection) {
        guard let tableView else { return }
        let announcement: String
        if newSelection.isEmpty {
            announcement = String(localized: "Cell selection cleared")
        } else if let rect = newSelection.boundingRectangle {
            let cellCount = newSelection.rectangles.reduce(0) { $0 + ($1.rows.count * $1.columns.count) }
            announcement = String(
                format: String(localized: "%d cells selected, rows %d to %d, columns %d to %d"),
                cellCount,
                rect.rows.lowerBound + 1,
                rect.rows.upperBound + 1,
                rect.columns.lowerBound + 1,
                rect.columns.upperBound + 1
            )
        } else {
            return
        }
        NSAccessibility.post(
            element: tableView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
        /// The announcement is a one-off sentence. This is the notification a table is supposed
        /// to post so assistive technology can re-read the selection on its own terms.
        NSAccessibility.post(element: tableView, notification: .selectedCellsChanged)
    }

    func clear() {
        guard !selection.isEmpty else { return }
        update(.empty)
    }

    func beginDrag(at coord: GridCoord, modifiers: NSEvent.ModifierFlags) -> MouseDisposition {
        let cleanModifiers = modifiers.intersection([.command, .shift, .option, .control])
        if cleanModifiers.contains(.command) && !cleanModifiers.contains(.shift) {
            dragOrigin = coord
            dragMode = .additive
            dragBaseSelection = selection
            return .replaceFocus(coord)
        }
        if cleanModifiers.contains(.shift) && !cleanModifiers.contains(.command) {
            let anchor = selection.anchor ?? coord
            dragOrigin = anchor
            dragMode = .replace
            dragBaseSelection = .empty
            update(.single(GridRect.between(anchor, coord), anchor: anchor, active: coord))
            return .replaceFocus(coord)
        }
        dragOrigin = coord
        dragMode = .replace
        dragBaseSelection = .empty
        if !selection.isEmpty {
            update(.empty)
        }
        return .replaceFocus(coord)
    }

    func continueDrag(to coord: GridCoord) {
        guard let origin = dragOrigin else { return }
        switch dragMode {
        case .replace:
            update(.single(GridRect.between(origin, coord), anchor: origin, active: coord))
        case .additive:
            var rectangles = dragBaseSelection.rectangles
            rectangles.append(GridRect.between(origin, coord))
            update(GridSelection(rectangles: rectangles, activeCell: coord, anchor: origin))
        }
    }

    func endDrag(dragged: Bool, originalCoord: GridCoord) {
        defer {
            dragOrigin = nil
            dragMode = .replace
            dragBaseSelection = .empty
        }
        guard !dragged, dragMode == .additive else { return }
        applyCmdClickToggle(at: originalCoord)
    }

    private func applyCmdClickToggle(at coord: GridCoord) {
        let cellRect = GridRect(cell: coord)
        var rectangles = dragBaseSelection.rectangles

        if let index = rectangles.firstIndex(where: { $0 == cellRect }) {
            rectangles.remove(at: index)
            if rectangles.isEmpty {
                update(.empty)
                return
            }
            let last = rectangles[rectangles.count - 1]
            let active = GridCoord(row: last.rows.lowerBound, displayColumn: last.columns.lowerBound)
            update(GridSelection(rectangles: rectangles, activeCell: active, anchor: dragBaseSelection.anchor))
            return
        }

        rectangles.append(cellRect)
        update(GridSelection(rectangles: rectangles, activeCell: coord, anchor: coord))
    }

    func selectEntireColumn(_ displayColumn: Int, totalRows: Int) {
        guard displayColumn >= 0, totalRows > 0 else { return }
        update(.column(displayColumn, totalRows: totalRows))
    }

    /// Toggles one column in and out of the selection, which is what Cmd+click means everywhere
    /// else on the system.
    ///
    /// Adding without a matching removal also grew the rectangle list without bound: `union`
    /// concatenates, so Cmd+clicking one heading twice left two identical rectangles behind, and
    /// the overlay, the row fill and `columns(in:)` each walk every rectangle for every visible row.
    func addEntireColumn(_ displayColumn: Int, totalRows: Int) {
        guard displayColumn >= 0, totalRows > 0 else { return }
        guard !selection.columns.contains(displayColumn) else {
            removeEntireColumn(displayColumn, totalRows: totalRows)
            return
        }
        let addition = GridSelection.column(displayColumn, totalRows: totalRows)
        update(selection.isEmpty ? addition : selection.union(addition))
    }

    private func removeEntireColumn(_ displayColumn: Int, totalRows: Int) {
        let dropped = GridRect(rows: 0...(totalRows - 1), columns: displayColumn...displayColumn)
        let rectangles = selection.rectangles.filter { $0 != dropped }
        var columns = selection.columns
        columns.remove(displayColumn)
        guard let last = rectangles.last else {
            update(.empty)
            return
        }
        let active = GridCoord(row: last.rows.lowerBound, displayColumn: last.columns.lowerBound)
        update(GridSelection(rectangles: rectangles, activeCell: active, anchor: active, columns: columns))
    }

    /// Display positions. `selectedFullColumnDataIndices()` is what a caller indexing column names
    /// or values wants.
    func selectedFullColumns() -> IndexSet {
        selection.columns
    }

    /// The fully selected columns as data indices, for callers that index `TableRows.columns` or a
    /// row's values. The inspector's CSV column insert and delete are the reason this exists: a
    /// display position used there deletes the wrong column of the user's file.
    func selectedFullColumnDataIndices() -> IndexSet {
        dataIndices(from: selection.columns)
    }

    /// Every column the selection touches, as data indices.
    func affectedDataColumns() -> IndexSet {
        dataIndices(from: selection.affectedColumns)
    }

    private func dataIndices(from positions: IndexSet) -> IndexSet {
        guard let coordinator else { return positions }
        return IndexSet(coordinator.dataColumnIndices(in: positions))
    }

    func selectEntireRow(_ row: Int, totalColumns: Int) {
        selectEntireRows([row], totalColumns: totalColumns)
    }

    /// Widens a selection to the whole of every row it touches, which is what Shift+Space asks for.
    ///
    /// One rectangle per contiguous run, not per row. Gaps have to survive, so a single spanning
    /// rectangle is wrong, but a rectangle per row is just as wrong at the other end: Select All
    /// then Shift+Space over a Fetch All result would build hundreds of thousands of them, and the
    /// overlay, the row fill and `columns(in:)` all walk every rectangle for every visible row.
    func selectEntireRows(_ rows: some Collection<Int>, totalColumns: Int) {
        guard totalColumns > 0 else { return }
        let sorted = rows.filter { $0 >= 0 }.sorted()
        guard let first = sorted.first else { return }
        let columns = 0...(totalColumns - 1)

        var rectangles: [GridRect] = []
        var runStart = first
        var runEnd = first
        for row in sorted.dropFirst() {
            if row == runEnd + 1 {
                runEnd = row
                continue
            }
            rectangles.append(GridRect(rows: runStart...runEnd, columns: columns))
            runStart = row
            runEnd = row
        }
        rectangles.append(GridRect(rows: runStart...runEnd, columns: columns))

        let anchor = GridCoord(row: first, displayColumn: 0)
        update(GridSelection(rectangles: rectangles, activeCell: anchor, anchor: anchor))
    }

    func extendActiveCell(from seed: GridCoord? = nil, direction: Direction, jumpToEdge: Bool, totalRows: Int, totalColumns: Int) {
        guard let active = selection.activeCell ?? seed else { return }
        let origin = selection.anchor ?? seed ?? active
        let next = step(from: active, direction: direction, jumpToEdge: jumpToEdge, totalRows: totalRows, totalColumns: totalColumns)
        update(.single(GridRect.between(origin, next), anchor: origin, active: next))
    }

    func moveActiveCell(direction: Direction, jumpToEdge: Bool, totalRows: Int, totalColumns: Int) -> GridCoord? {
        guard let active = selection.activeCell else { return nil }
        let next = step(from: active, direction: direction, jumpToEdge: jumpToEdge, totalRows: totalRows, totalColumns: totalColumns)
        update(.single(GridRect(cell: next), anchor: next, active: next))
        return next
    }

    private func step(from coord: GridCoord, direction: Direction, jumpToEdge: Bool, totalRows: Int, totalColumns: Int) -> GridCoord {
        switch direction {
        case .up:
            return GridCoord(row: jumpToEdge ? 0 : max(0, coord.row - 1), displayColumn: coord.displayColumn)
        case .down:
            return GridCoord(
                row: jumpToEdge ? max(0, totalRows - 1) : min(totalRows - 1, coord.row + 1),
                displayColumn: coord.displayColumn
            )
        case .left:
            return GridCoord(row: coord.row, displayColumn: jumpToEdge ? 0 : max(0, coord.displayColumn - 1))
        case .right:
            return GridCoord(
                row: coord.row,
                displayColumn: jumpToEdge
                    ? max(0, totalColumns - 1)
                    : min(totalColumns - 1, coord.displayColumn + 1)
            )
        }
    }

    private func reloadColumns(for old: GridSelection, new: GridSelection) -> IndexSet {
        let union = old.affectedColumns.union(new.affectedColumns)
        if let headerView = (tableView as? KeyHandlingTableView)?.headerView as? SortableHeaderView {
            headerView.updateColumnSelectionIndicators(
                selectedColumns: new.columns,
                dirtyColumns: union.union(old.columns).union(new.columns)
            )
        }
        return union
    }

    private func reloadRowsForFill(old: GridSelection, new: GridSelection, dirtyColumns: IndexSet) {
        guard let tableView = tableView else { return }
        guard tableView.numberOfRows > 0 else { return }

        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let visibleRange = visible.location..<(visible.location + visible.length)

        var rowsToReload = IndexSet()
        let oldVisible = old.affectedRows.intersection(IndexSet(integersIn: visibleRange))
        let newVisible = new.affectedRows.intersection(IndexSet(integersIn: visibleRange))
        rowsToReload.formUnion(oldVisible.symmetricDifference(newVisible))
        for row in newVisible where new.columns(in: row) != old.columns(in: row) {
            rowsToReload.insert(row)
        }
        if rowsToReload.isEmpty { return }

        for row in rowsToReload {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView)?.needsDisplay = true
        }
    }
}

enum MouseDisposition {
    case replaceFocus(GridCoord)
    case clearFocus
    case clickThrough
}

private extension IndexSet {
    func symmetricDifference(_ other: IndexSet) -> IndexSet {
        var result = self
        result.formUnion(other)
        let common = self.intersection(other)
        result.subtract(common)
        return result
    }
}
