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
            let active = GridCoord(row: last.rows.lowerBound, column: last.columns.lowerBound)
            update(GridSelection(rectangles: rectangles, activeCell: active, anchor: dragBaseSelection.anchor))
            return
        }

        rectangles.append(cellRect)
        update(GridSelection(rectangles: rectangles, activeCell: coord, anchor: coord))
    }

    func selectAll(totalRows: Int, totalColumns: Int) {
        guard totalRows > 0, totalColumns > 0 else { return }
        let rect = GridRect(rows: 0...(totalRows - 1), columns: 0...(totalColumns - 1))
        let active = GridCoord(row: 0, column: 0)
        update(.single(rect, anchor: active, active: active))
    }

    func selectEntireColumn(_ column: Int, totalRows: Int) {
        guard column >= 0, totalRows > 0 else { return }
        let rect = GridRect(rows: 0...(totalRows - 1), columns: column...column)
        let anchor = GridCoord(row: 0, column: column)
        update(.single(rect, anchor: anchor, active: anchor))
    }

    func selectEntireRow(_ row: Int, totalColumns: Int) {
        guard row >= 0, totalColumns > 0 else { return }
        let rect = GridRect(rows: row...row, columns: 0...(totalColumns - 1))
        let anchor = GridCoord(row: row, column: 0)
        update(.single(rect, anchor: anchor, active: anchor))
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
            return GridCoord(row: jumpToEdge ? 0 : max(0, coord.row - 1), column: coord.column)
        case .down:
            return GridCoord(row: jumpToEdge ? max(0, totalRows - 1) : min(totalRows - 1, coord.row + 1), column: coord.column)
        case .left:
            return GridCoord(row: coord.row, column: jumpToEdge ? 0 : max(0, coord.column - 1))
        case .right:
            return GridCoord(row: coord.row, column: jumpToEdge ? max(0, totalColumns - 1) : min(totalColumns - 1, coord.column + 1))
        }
    }

    private func reloadColumns(for old: GridSelection, new: GridSelection) -> IndexSet {
        let union = old.affectedColumns.union(new.affectedColumns)
        if let headerView = (tableView as? KeyHandlingTableView)?.headerView as? SortableHeaderView {
            headerView.updateColumnSelectionIndicators(
                selectedColumns: fullySelectedColumns(in: new),
                dirtyColumns: union
            )
        }
        return union
    }

    private func fullySelectedColumns(in selection: GridSelection) -> IndexSet {
        guard let totalRows = tableView?.numberOfRows, totalRows > 0 else { return IndexSet() }
        var fully = IndexSet()
        for rect in selection.rectangles where rect.rows.lowerBound <= 0 && rect.rows.upperBound >= totalRows - 1 {
            fully.insert(integersIn: rect.columns.lowerBound...rect.columns.upperBound)
        }
        return fully
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
