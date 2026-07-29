import AppKit

@MainActor
final class GridSelectionOverlay: NSView {
    var selection: GridSelection = .empty {
        didSet {
            guard oldValue != selection else { return }
            needsDisplay = true
        }
    }

    weak var tableView: NSTableView?
    weak var coordinator: TableViewCoordinator?

    private static let borderWidth: CGFloat = 1.0
    private static let activeCellBorderWidth: CGFloat = 2.0
    private static let borderAlpha: CGFloat = 0.7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView, let coordinator else { return }
        let totalRows = tableView.numberOfRows
        let editingCell = activeOverlayCell(in: coordinator)

        NSColor.selectedContentBackgroundColor.withAlphaComponent(Self.borderAlpha).setStroke()
        for rect in selection.rectangles {
            guard let frame = frame(for: rect, in: tableView, coordinator: coordinator) else { continue }
            guard frame.intersects(dirtyRect) else { continue }
            if isFullHeight(rect, totalRows: totalRows) { continue }
            if let editingCell, rect.contains(editingCell) { continue }
            let inset = frame.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
            let path = NSBezierPath(rect: inset)
            path.lineWidth = Self.borderWidth
            path.stroke()
        }

        if let active = selection.activeCell,
           editingCell != active,
           selection.rectangles.count > 1 || (selection.rectangles.first?.rows.count ?? 0) > 1 || (selection.rectangles.first?.columns.count ?? 0) > 1,
           let frame = frame(for: GridRect(cell: active), in: tableView, coordinator: coordinator),
           frame.intersects(dirtyRect) {
            NSColor.controlAccentColor.setStroke()
            let inset = frame.insetBy(dx: Self.activeCellBorderWidth / 2, dy: Self.activeCellBorderWidth / 2)
            let path = NSBezierPath(rect: inset)
            path.lineWidth = Self.activeCellBorderWidth
            path.stroke()
        }
    }

    private func activeOverlayCell(in coordinator: TableViewCoordinator) -> GridCoord? {
        if let editor = coordinator.overlayEditor, editor.isActive {
            return GridCoord(row: editor.row, column: editor.columnIndex)
        }
        if let viewer = coordinator.overlayViewer, viewer.isActive {
            return GridCoord(row: viewer.row, column: viewer.columnIndex)
        }
        return nil
    }

    private func isFullHeight(_ rect: GridRect, totalRows: Int) -> Bool {
        guard totalRows > 0 else { return false }
        return rect.rows.lowerBound <= 0 && rect.rows.upperBound >= totalRows - 1
    }

    private func frame(for rect: GridRect, in tableView: NSTableView, coordinator: TableViewCoordinator) -> NSRect? {
        guard tableView.numberOfRows > 0, tableView.numberOfColumns > 0 else { return nil }
        let firstRow = max(0, rect.rows.lowerBound)
        let lastRow = min(tableView.numberOfRows - 1, rect.rows.upperBound)
        guard firstRow <= lastRow else { return nil }

        let rowRectTop = tableView.rect(ofRow: firstRow)
        let rowRectBottom = tableView.rect(ofRow: lastRow)
        let topY = rowRectTop.minY
        let bottomY = rowRectBottom.maxY

        var leadingX = CGFloat.infinity
        var trailingX = -CGFloat.infinity
        for dataColumn in rect.columns.lowerBound...rect.columns.upperBound {
            guard let tableColumnIndex = coordinator.tableColumnIndex(for: dataColumn) else { continue }
            let columnRect = tableView.rect(ofColumn: tableColumnIndex)
            leadingX = min(leadingX, columnRect.minX)
            trailingX = max(trailingX, columnRect.maxX)
        }
        guard trailingX > leadingX else { return nil }
        return NSRect(x: leadingX, y: topY, width: trailingX - leadingX, height: bottomY - topY)
    }
}
