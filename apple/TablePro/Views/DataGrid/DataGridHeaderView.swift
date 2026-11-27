//
//  DataGridHeaderView.swift
//  TablePro
//

import AppKit

// The menu is resolved from the event, and drawn cells need a repaint on each step of a column drag.
@MainActor
final class DataGridHeaderView: ThemeTableHeaderView {
    var paneKind: DataGridPane.Kind = .main
    private var bodyFollowsColumnDrag = false

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

    // AppKit redraws the header on every step of a resize or reorder drag but posts the column notifications only at mouse-up.
    override func viewWillDraw() {
        super.viewWillDraw()
        let isDragging = resizedColumn >= 0 || draggedColumn >= 0
        guard isDragging || bodyFollowsColumnDrag else { return }
        bodyFollowsColumnDrag = isDragging
        controller?.headerGeometryDidStep(in: paneKind)
    }

    // Every scroll step drops the cursor rects, and AppKit's pass adds one for every column, asking for the visible
    // columns again for each: 75 M instructions a step at 500 columns (measured on macOS 27).
    override func resetCursorRects() {
        guard let tableView, tableView.userInterfaceLayoutDirection == .leftToRight else {
            super.resetCursorRects()
            return
        }
        for resize in DataGridHeaderCursor.resizeRects(in: self, of: tableView) {
            addCursorRect(resize.rect, cursor: resize.cursor)
        }
    }
}

// AppKit's own divider geometry and cursors, measured on macOS 27, for the columns the header shows.
@MainActor
enum DataGridHeaderCursor {
    struct Resize: Equatable {
        let rect: NSRect
        let cursor: NSCursor
    }

    static let width: CGFloat = 5
    static let leadingInset: CGFloat = 3
    // The last divider has nothing after it, so AppKit gives it a wider target.
    static let lastWidth: CGFloat = 9
    static let lastLeadingInset: CGFloat = 5

    static func resizeRects(in header: NSTableHeaderView, of tableView: NSTableView) -> [Resize] {
        guard tableView.allowsColumnResizing else { return [] }
        let visible = header.visibleRect
        guard visible.width > 0 else { return [] }
        let columns = tableView.tableColumns
        let shown = tableView.columnIndexes(in: NSRect(x: visible.minX, y: tableView.bounds.minY, width: visible.width, height: 1))
        guard let first = shown.first, let last = shown.last, last < columns.count else { return [] }
        // The divider before the first shown column reaches into view.
        return (max(first - 1, 0)...last).compactMap { index in
            let column = columns[index]
            guard !column.isHidden, column.resizingMask.contains(.userResizingMask) else { return nil }
            let header = header.headerRect(ofColumn: index)
            let isLast = index == columns.count - 1
            let rect = NSRect(
                x: header.maxX - (isLast ? lastLeadingInset : leadingInset),
                y: header.minY,
                width: isLast ? lastWidth : width,
                height: header.height
            )
            return Resize(rect: rect, cursor: cursor(for: column))
        }
    }

    private enum Direction {
        case left
        case right
        case both
    }

    static func cursor(for column: NSTableColumn) -> NSCursor {
        if column.width <= column.minWidth {
            return resize(.right)
        }
        if column.width >= column.maxWidth {
            return resize(.left)
        }
        return resize(.both)
    }

    private static func resize(_ direction: Direction) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch direction {
            case .left: return .columnResize(directions: .left)
            case .right: return .columnResize(directions: .right)
            case .both: return .columnResize(directions: .all)
            }
        }
        switch direction {
        case .left: return .resizeLeft
        case .right: return .resizeRight
        case .both: return .resizeLeftRight
        }
    }
}
