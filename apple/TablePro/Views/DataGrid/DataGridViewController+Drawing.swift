//
//  DataGridViewController+Drawing.swift
//  TablePro
//

import AppKit

extension DataGridViewController {
    // The full row in a whole-row selection, else the selected columns' span: NSTableView selects rows, not rectangles.
    func selectionRects(forRow row: Int, in table: DataGridTableView, within tableRect: NSRect) -> [NSRect] {
        guard row >= 0, let pane = container.pane(of: table) else { return [] }
        let columns = model.columns
        let selected = model.selection.columns(in: row)
        guard !selected.isEmpty, !columns.isEmpty else { return [] }
        if selected.contains(integersIn: 0..<columns.count) {
            return [table.rect(ofRow: row)]
        }
        return table.columnIndexes(in: tableRect).compactMap { index in
            guard case .data(let id)? = pane.slot(atTableIndex: index, columns: columns),
                  let position = columns.displayPosition(of: id),
                  selected.contains(position) else { return nil }
            return table.rect(ofColumn: index)
        }
    }

    func drawCells(ofRow row: Int, in dirtyRect: NSRect, of view: NSView, table: DataGridTableView, isEmphasized: Bool) {
        guard row >= 0, let pane = container.pane(of: table),
              let pass = presenter.makePass(in: NSAppearance.currentDrawing()),
              let rowModel = model.order.row(at: row, in: pass.rows) else { return }
        let columns = model.columns
        let visualState = presenter.visualState(of: rowModel)
        let selected = pass.selection.columns(in: row)
        let line = DrawnRow(
            row: row,
            model: rowModel,
            visualState: visualState,
            selected: selected,
            isWholeRow: !columns.isEmpty && selected.contains(integersIn: 0..<columns.count),
            isEmphasized: isEmphasized,
            pass: pass
        )
        let dragged = Self.draggedColumnIndex(of: table)
        for index in table.columnIndexes(in: view.convert(dirtyRect, to: table)) where index != dragged {
            drawCell(atTableIndex: index, in: table.rect(ofColumn: index), of: view, table: table, pane: pane, line: line)
        }
        // After every cell: a cell fills its whole rect for a tint and would paint over a line drawn beside it.
        DataGridBodyChrome.drawColumnSeparators(in: dirtyRect, of: view, tableView: table)
        if let dragged {
            drawDraggedColumn(dragged, in: dirtyRect, of: view, table: table, pane: pane, line: line)
        }
        drawActiveCellBorder(of: view, table: table, pane: pane, line: line)
        if pane.kind == .frozen {
            drawFrozenPaneEdge(in: dirtyRect, of: view)
        }
    }

    private struct DrawnRow {
        let row: Int
        let model: Row
        let visualState: RowVisualState
        let selected: IndexSet
        let isWholeRow: Bool
        let isEmphasized: Bool
        let pass: DataGridCellPresenter.Pass
    }

    private func drawCell(
        atTableIndex index: Int,
        in rectInTable: NSRect,
        of view: NSView,
        table: DataGridTableView,
        pane: DataGridPane,
        line: DrawnRow
    ) {
        let columnRect = view.convert(rectInTable, from: table)
        let cellRect = NSRect(x: columnRect.minX, y: 0, width: columnRect.width, height: view.bounds.height)
        switch pane.slot(atTableIndex: index, columns: model.columns) {
        case .rowNumber:
            let number = (model.dataSource?.gridRowNumberOffset ?? 0) + line.row + 1
            presenter.renderer.drawRowNumber(
                number,
                in: cellRect,
                font: line.pass.palette.rowNumberFont,
                color: line.pass.palette.rowNumberColor(
                    for: line.visualState,
                    onEmphasizedSelection: line.isWholeRow && line.isEmphasized
                )
            )
        case .data(let id):
            guard let position = model.columns.displayPosition(of: id),
                  let column = model.columns.column(at: position),
                  editedCell != GridCoord(row: line.row, displayColumn: position),
                  let appearance = presenter.appearance(
                      of: line.model,
                      displayRow: line.row,
                      column: column,
                      visualState: line.visualState,
                      pass: line.pass,
                      onEmphasizedSelection: line.isEmphasized && line.selected.contains(position)
                  ) else { return }
            presenter.renderer.draw(appearance, in: cellRect, controlView: view)
        case nil:
            return
        }
    }

    // The column a header drag is moving, drawn at the pointer over its neighbours, the way AppKit floats cell views.
    private func drawDraggedColumn(
        _ dragged: Int,
        in dirtyRect: NSRect,
        of view: NSView,
        table: DataGridTableView,
        pane: DataGridPane,
        line: DrawnRow
    ) {
        guard let distance = table.headerView?.draggedDistance,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let floating = table.rect(ofColumn: dragged).offsetBy(dx: distance, dy: 0)
        guard floating.intersects(view.convert(dirtyRect, to: table)) else { return }
        context.saveGState()
        context.setAlpha(Self.draggedColumnAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawCell(atTableIndex: dragged, in: floating, of: view, table: table, pane: pane, line: line)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // The alphaValue AppKit gives a floated column's cell views, measured on macOS 27; AppKit does not publish it.
    private static let draggedColumnAlpha: CGFloat = 0.6

    private static func draggedColumnIndex(of table: NSTableView) -> Int? {
        guard let dragged = table.headerView?.draggedColumn, dragged >= 0, dragged < table.numberOfColumns else { return nil }
        return dragged
    }

    // An inner stroke, 2 pt while the grid has focus and 1 pt otherwise: a focus ring from a row view loses its top
    // and bottom (critic B M5). On an emphasized fill it takes the selected text color, which stays visible there.
    private func drawActiveCellBorder(of view: NSView, table: DataGridTableView, pane: DataGridPane, line: DrawnRow) {
        guard let active = line.pass.selection.activeCell, active.row == line.row,
              editedCell != active,
              let index = pane.tableIndex(forDisplayPosition: active.displayColumn, columns: model.columns) else { return }
        let columnRect = view.convert(table.rect(ofColumn: index), from: table)
        let lineWidth: CGFloat = gridHasFocus ? 2 : 1
        let cellRect = NSRect(
            x: columnRect.minX,
            y: 0,
            width: max(0, columnRect.width - table.intercellSpacing.width),
            height: view.bounds.height
        )
        let onFill = line.isEmphasized && line.selected.contains(active.displayColumn)
        let color = onFill ? line.pass.palette.selectionText : NSColor.keyboardFocusIndicatorColor
        let path = NSBezierPath(rect: cellRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }
}
