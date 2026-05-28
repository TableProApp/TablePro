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

    private static let borderWidth: CGFloat = 1.5

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
        let schema = coordinator.identitySchema

        let borderColor = NSColor.selectedContentBackgroundColor
        borderColor.setStroke()

        for rect in selection.rectangles {
            guard let frame = frame(for: rect, in: tableView, schema: schema) else { continue }
            guard frame.intersects(dirtyRect) else { continue }
            let inset = frame.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
            let path = NSBezierPath(rect: inset)
            path.lineWidth = Self.borderWidth
            path.stroke()
        }
    }

    private func frame(for rect: GridRect, in tableView: NSTableView, schema: ColumnIdentitySchema) -> NSRect? {
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
            guard let tableColumnIndex = DataGridView.tableColumnIndex(for: dataColumn, in: tableView, schema: schema) else { continue }
            let columnRect = tableView.rect(ofColumn: tableColumnIndex)
            leadingX = min(leadingX, columnRect.minX)
            trailingX = max(trailingX, columnRect.maxX)
        }
        guard trailingX > leadingX else { return nil }
        return NSRect(x: leadingX, y: topY, width: trailingX - leadingX, height: bottomY - topY)
    }
}
