//
//  DataGridHeaderView.swift
//  TablePro
//

import AppKit

// The menu is resolved from the event, drawn cells need a repaint on each step of a column drag, and a second line can
// show each column's type.
@MainActor
final class DataGridHeaderView: ThemeTableHeaderView {
    var paneKind: DataGridPane.Kind = .main
    private var bodyFollowsColumnDrag = false
    private var standardHeight: CGFloat = 0

    // The type line makes the header one line taller; a column without a type leaves its line empty.
    var showsTypeLine = false {
        didSet {
            guard showsTypeLine != oldValue else { return }
            if standardHeight == 0 {
                standardHeight = frame.height
            }
            setFrameSize(NSSize(width: frame.width, height: Self.height(standard: standardHeight, showsTypeLine: showsTypeLine)))
            needsDisplay = true
        }
    }

    static func height(standard: CGFloat, showsTypeLine: Bool) -> CGFloat {
        showsTypeLine ? standard + DataGridHeaderTypeLine.lineHeight : standard
    }

    private var controller: DataGridViewController? {
        (tableView as? DataGridTableView)?.controller
    }

    override var themeScope: ThemeScope {
        controller?.model.themeScope ?? .live
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tableView else { return nil }
        let index = column(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, index < tableView.tableColumns.count else { return nil }
        return controller?.headerMenu(forTableColumn: tableView.tableColumns[index], in: paneKind)
    }

    // The title keeps AppKit's band on top and the type line sits under it, the two centered together.
    override func contentRect(forCellFrame cellFrame: NSRect) -> NSRect {
        guard showsTypeLine else { return super.contentRect(forCellFrame: cellFrame) }
        let height = min(ThemeTableHeaderCell.interiorHeight + DataGridHeaderTypeLine.lineHeight, cellFrame.height)
        return NSRect(x: cellFrame.minX, y: cellFrame.midY - height / 2, width: cellFrame.width, height: height)
    }

    override func drawBelowTitle(of cell: ThemeTableHeaderCell, in rect: NSRect, cellFrame: NSRect) {
        guard showsTypeLine, let controller, let tableColumn = tableColumn(drawnBy: cell, in: cellFrame),
              let line = controller.headerTypeLine(for: tableColumn, in: paneKind) else { return }
        line.draw(in: rect, color: DataGridHeaderTypeLine.color(in: themeScope))
    }

    // AppKit draws past the last column with a copy of a cell, which belongs to no column and gets no type line.
    private func tableColumn(drawnBy cell: NSCell, in cellFrame: NSRect) -> NSTableColumn? {
        guard let tableView else { return nil }
        let columns = tableView.tableColumns
        let dragged = draggedColumn
        if dragged >= 0, dragged < columns.count, columns[dragged].headerCell === cell {
            return columns[dragged]
        }
        let index = column(at: NSPoint(x: cellFrame.midX, y: cellFrame.midY))
        if index >= 0, index < columns.count, columns[index].headerCell === cell {
            return columns[index]
        }
        return columns.first { $0.headerCell === cell }
    }

    // AppKit redraws the header on every step of a resize or reorder drag but posts the column notifications only at mouse-up.
    override func viewWillDraw() {
        super.viewWillDraw()
        let isDragging = resizedColumn >= 0 || draggedColumn >= 0
        guard isDragging || bodyFollowsColumnDrag else { return }
        bodyFollowsColumnDrag = isDragging
        controller?.headerGeometryDidStep(in: paneKind)
    }
}
