//
//  DataGridActiveCellBorderTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct DataGridActiveCellBorderTests {
    // Whole-point widths, so every column edge lands on a pixel of a 1x bitmap.
    private func makeGrid() -> HostedDataGrid {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 80, "name": 120, "age": 80]
        let grid = HostedDataGrid(
            rows: GridFixtureRows.people,
            store: InMemoryDataGridStateStore(columnLayout: layout)
        )
        grid.model.setSelection(GridSelectionReducer.single(GridCoord(row: 0, displayColumn: 1)))
        grid.layout()
        return grid
    }

    // Drawn the way the row view draws itself, into a flipped bitmap rather than through cacheDisplay.
    private func render(row: Int, in grid: HostedDataGrid) throws -> (rowView: DataGridRowView, bitmap: NSBitmapImageRep) {
        let rowView = try #require(grid.main.rowView(atRow: row, makeIfNecessary: true) as? DataGridRowView)
        let content = try #require(rowView.subviews.first { $0 is DataGridRowContentView })
        let bounds = rowView.bounds
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width.rounded(.up)),
            pixelsHigh: Int(bounds.height.rounded(.up)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let aqua = try #require(NSAppearance(named: .aqua))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        aqua.performAsCurrentDrawingAppearance {
            rowView.drawBackground(in: bounds)
            rowView.drawSelection(in: bounds)
            content.draw(content.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return (rowView, bitmap)
    }

    private func leadingEdge(ofDisplayPosition position: Int, in grid: HostedDataGrid, rowView: NSView) throws -> Int {
        let index = try #require(grid.tableIndex(ofDisplayPosition: position))
        return Int(rowView.convert(grid.main.rect(ofColumn: index), from: grid.main).minX)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int) throws -> NSColor {
        try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func differs(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        max(
            abs(lhs.redComponent - rhs.redComponent),
            abs(lhs.greenComponent - rhs.greenComponent),
            abs(lhs.blueComponent - rhs.blueComponent)
        ) > 0.08
    }

    @Test("The active cell draws a 2 pt inner border while the grid has focus")
    func focusedBorderIsTwoPoints() throws {
        let grid = makeGrid()
        defer { grid.close() }
        #expect(grid.focus())
        #expect(grid.controller.gridHasFocus)

        let (rowView, bitmap) = try render(row: 0, in: grid)
        try #require(rowView.isSelected)
        let edge = try leadingEdge(ofDisplayPosition: 1, in: grid, rowView: rowView)

        let outer = try pixel(bitmap, x: edge)
        let inner = try pixel(bitmap, x: edge + 1)
        let fill = try pixel(bitmap, x: edge + 2)
        #expect(!differs(outer, inner))
        #expect(differs(inner, fill))
    }

    @Test("The active cell draws a 1 pt inner border while the grid does not have focus")
    func unfocusedBorderIsOnePoint() throws {
        let grid = makeGrid()
        defer { grid.close() }
        #expect(!grid.controller.gridHasFocus)

        let (rowView, bitmap) = try render(row: 0, in: grid)
        let edge = try leadingEdge(ofDisplayPosition: 1, in: grid, rowView: rowView)

        let outer = try pixel(bitmap, x: edge)
        let inner = try pixel(bitmap, x: edge + 1)
        let fill = try pixel(bitmap, x: edge + 2)
        #expect(differs(outer, inner))
        #expect(!differs(inner, fill))
    }

    @Test("A cell beside the active cell draws no border")
    func otherCellsDrawNoBorder() throws {
        let grid = makeGrid()
        defer { grid.close() }

        let (rowView, bitmap) = try render(row: 0, in: grid)
        let edge = try leadingEdge(ofDisplayPosition: 2, in: grid, rowView: rowView)

        let border = try pixel(bitmap, x: edge)
        let fill = try pixel(bitmap, x: edge + 2)
        #expect(!differs(border, fill))
    }

    @Test("A row without the active cell draws no border at its column")
    func otherRowsDrawNoBorder() throws {
        let grid = makeGrid()
        defer { grid.close() }

        let (rowView, bitmap) = try render(row: 2, in: grid)
        let edge = try leadingEdge(ofDisplayPosition: 1, in: grid, rowView: rowView)

        let border = try pixel(bitmap, x: edge)
        let fill = try pixel(bitmap, x: edge + 2)
        #expect(!differs(border, fill))
    }
}
