//
//  DataGridActiveCellBorderTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct DataGridActiveCellBorderTests {
    // Whole-point widths, so every column edge lands on a pixel of a 1x bitmap.
    private func makeGrid(scope: ThemeScope = .live) -> HostedDataGrid {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 80, "name": 120, "age": 80]
        let grid = HostedDataGrid(
            rows: GridFixtureRows.people,
            store: InMemoryDataGridStateStore(columnLayout: layout),
            prepare: { _, model in model.themeScope = scope }
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

    private func isGreen(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5 && color.greenComponent > 0.75 && color.redComponent < 0.45 && color.blueComponent < 0.45
    }

    private func scope(_ overrides: [ThemeSlot: String]) throws -> ThemeScope {
        .fixed(try ThemeTestFixture.theme(.light, overrides))
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

    // MARK: - Theme

    @Test("With focus the selection fills in the theme's selection and the active cell takes the theme's selected text")
    func focusedSelectionTakesTheTheme() throws {
        let grid = makeGrid(scope: try scope([
            .gridSelection: "#00FF00",
            .gridSelectionText: "#FF00FF",
            .gridFocusBorder: "#0000FF",
        ]))
        defer { grid.close() }
        #expect(grid.focus())

        let (rowView, bitmap) = try render(row: 0, in: grid)
        let edge = try leadingEdge(ofDisplayPosition: 1, in: grid, rowView: rowView)

        let border = try pixel(bitmap, x: edge)
        let fill = try pixel(bitmap, x: edge + 2)
        #expect(ThemeTestFixture.isMagenta(border), "border drew \(border)")
        #expect(isGreen(fill), "fill drew \(fill)")
    }

    @Test("Without focus the selection fills in the theme's inactive selection and the active cell takes the theme's focus border")
    func unfocusedSelectionTakesTheTheme() throws {
        let grid = makeGrid(scope: try scope([
            .gridInactiveSelection: "#00FF00",
            .gridFocusBorder: "#FF00FF",
            .gridSelectionText: "#0000FF",
        ]))
        defer { grid.close() }
        #expect(!grid.controller.gridHasFocus)

        let (rowView, bitmap) = try render(row: 0, in: grid)
        let edge = try leadingEdge(ofDisplayPosition: 1, in: grid, rowView: rowView)

        let border = try pixel(bitmap, x: edge)
        let fill = try pixel(bitmap, x: edge + 2)
        #expect(ThemeTestFixture.isMagenta(border), "border drew \(border)")
        #expect(isGreen(fill), "fill drew \(fill)")
    }
}
