//
//  DataGridBodyChromeTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTheme
import Testing

// gridStyleMask stays empty (#2381), so these measure the separators the grid draws itself, through
// rect(ofColumn:) and the pixels rather than the chrome's own arithmetic.
@MainActor
struct DataGridBodyChromeTests {
    private func makeGrid(columns: [String], rows: Int = 3) -> HostedDataGrid {
        let queryRows = (0 ..< rows).map { row in
            columns.map { PluginCellValue.text("\($0)-\(row)") }
        }
        let tableRows = TableRows.from(
            queryRows: queryRows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        var layout = ColumnLayoutState()
        for column in columns {
            layout.columnWidths[column] = 120
        }
        return HostedDataGrid(rows: tableRows, store: InMemoryDataGridStateStore(columnLayout: layout))
    }

    private func bitmap(width: CGFloat, height: CGFloat) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width.rounded(.up)),
            pixelsHigh: Int(height.rounded(.up)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
    }

    // Flipped, as the table and its row views are, so a rect's minY is the bitmap's top row.
    private func drawFlipped(into rep: NSBitmapImageRep, height: CGFloat, appearance: NSAppearance, _ draw: () -> Void) throws {
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: height)
        context.cgContext.scaleBy(x: 1, y: -1)
        appearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
    }

    // A partial repaint invalidates one cell, and rect(ofColumn:) includes the intercell spacing the next separator sits in.
    @Test("Repainting one cell redraws the separator standing inside its rect")
    func partialRepaintRedrawsTheSeparatorInsideIt() throws {
        let grid = makeGrid(columns: ["id", "name", "total"])
        defer { grid.close() }
        let table = grid.main
        let first = try #require(grid.tableIndex(ofDisplayPosition: 0))
        let next = try #require(grid.tableIndex(ofDisplayPosition: 1))
        let cellRect = table.rect(ofColumn: first)
        let neighbourSeparator = table.rect(ofColumn: next).minX - DataGridBodyChrome.separatorThickness

        #expect(neighbourSeparator >= cellRect.minX && neighbourSeparator < cellRect.maxX)

        let separators = DataGridBodyChrome.separatorRects(in: cellRect, of: table, tableView: table)

        #expect(separators.contains { $0.minX == neighbourSeparator })
    }

    @Test("A separator stands at the leading edge of every column after the first")
    func separatorsSitAtLeadingEdges() {
        let grid = makeGrid(columns: ["id", "name", "total"])
        defer { grid.close() }
        let table = grid.main

        let separators = DataGridBodyChrome.separatorRects(in: table.bounds, of: table, tableView: table)

        let expected = table.tableColumns.indices
            .map { table.rect(ofColumn: $0) }
            .filter { $0.minX > 0 }
            .map { $0.minX - DataGridBodyChrome.separatorThickness }
        #expect(expected.count == table.tableColumns.count - 1)
        #expect(separators.map { $0.minX } == expected)
        #expect(separators.allSatisfy { $0.width == DataGridBodyChrome.separatorThickness })
    }

    @Test("The row-number column, first in the table, is given no separator of its own")
    func rowNumberColumnHasNoSeparator() throws {
        let grid = makeGrid(columns: ["id", "name"])
        defer { grid.close() }
        let table = grid.main
        let rowNumber = try #require(grid.controller.main.rowNumberTableColumn)
        let rowNumberIndex = table.column(withIdentifier: rowNumber.identifier)

        #expect(rowNumberIndex == 0)
        let separators = DataGridBodyChrome.separatorRects(in: table.bounds, of: table, tableView: table)
        #expect(!separators.contains { $0.maxX <= 0 })
        #expect(separators.first?.maxX == table.rect(ofColumn: 1).minX)
    }

    // NSTableView's own grid color is separatorColor, not NSColor.gridColor, which in dark mode is darker than the rows.
    @Test("Without a theme override the table keeps AppKit's own grid and background colours")
    func defaultThemeKeepsTheTableDefaults() {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(ThemeSelection(pair: .builtIn, effectiveAppearance: .light))

        let tableView = NSTableView()
        let stock = NSTableView()
        tableView.gridColor = .systemRed
        tableView.backgroundColor = .systemRed
        DataGridBodyChrome.applyThemeColors(to: tableView, scope: .live)

        #expect(tableView.gridColor == .separatorColor)
        #expect(tableView.gridColor == stock.gridColor)
        #expect(tableView.backgroundColor == .controlBackgroundColor)
        #expect(tableView.backgroundColor == stock.backgroundColor)
    }

    @Test("A theme's grid line and background become the table's colours")
    func themeOverridesBecomeTheTableColors() throws {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        var theme = BuiltInThemes.light
        theme.id = "test.body-chrome"
        theme.overrides[.gridLine] = try ThemeColor(validating: "#FF0000")
        theme.overrides[.gridBackground] = try ThemeColor(validating: "#102030")
        engine.adopt(ThemeSelection(pair: ThemePair(light: theme, dark: BuiltInThemes.dark), effectiveAppearance: .light))

        let tableView = NSTableView()
        DataGridBodyChrome.applyThemeColors(to: tableView, scope: .live)

        #expect(tableView.gridColor == engine.resolved[.gridLine])
        #expect(tableView.backgroundColor == engine.resolved[.gridBackground])
        #expect(tableView.gridColor != .separatorColor)
    }

    // The table's gridColor is the dynamic catalog color, so an appearance change carries the separator with it.
    @Test("The separator is drawn in the table view's own grid colour")
    func separatorUsesTheTableViewGridColor() throws {
        let grid = makeGrid(columns: ["id", "name"])
        defer { grid.close() }
        let table = grid.main
        table.gridColor = .systemRed
        let rowView = try #require(table.rowView(atRow: 0, makeIfNecessary: true) as? DataGridRowView)
        let content = try #require(rowView.subviews.first { $0 is DataGridRowContentView })
        let bounds = rowView.bounds
        let rep = try bitmap(width: bounds.width, height: bounds.height)
        let aqua = try #require(NSAppearance(named: .aqua))
        try drawFlipped(into: rep, height: bounds.height, appearance: aqua) {
            rowView.drawBackground(in: bounds)
            content.draw(content.bounds)
        }

        let firstData = try #require(grid.tableIndex(ofDisplayPosition: 0))
        let boundary = rowView.convert(table.rect(ofColumn: firstData), from: table).minX
        let sampled = try #require(rep.colorAt(x: Int(boundary - 0.5), y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let expected = try #require(NSColor.systemRed.usingColorSpace(.deviceRGB))

        #expect(abs(sampled.redComponent - expected.redComponent) < 0.15)
        #expect(sampled.redComponent > sampled.greenComponent + 0.3)
    }

    @Test("Past the last row, bands continue one row apart, numbered on from the last row")
    func bandsContinuePastTheLastRow() throws {
        let grid = makeGrid(columns: ["id", "name"], rows: 3)
        defer { grid.close() }
        let table = grid.main
        let bounds = table.bounds
        let bands = DataGridBodyChrome.rowBands(in: bounds, of: table, tableView: table)

        let rows = Array(bands.prefix(3))
        let past = Array(bands.dropFirst(3))
        let rowIndexes = rows.map { $0.row }
        let rowsAreTableRows = rows.allSatisfy { $0.isTableRow }
        let pastIndexes = past.map { $0.row }
        let pastAreTableRows = past.contains { $0.isTableRow }

        #expect(rowIndexes == [0, 1, 2])
        #expect(rowsAreTableRows)
        #expect(!past.isEmpty)
        #expect(pastIndexes == Array(3..<(3 + past.count)))
        #expect(!pastAreTableRows)
        let lastRowBottom = table.rect(ofRow: 2).maxY
        for (offset, band) in past.enumerated() {
            #expect(band.rect.minY == lastRowBottom + CGFloat(offset) * table.rowHeight)
            #expect(band.rect.height == table.rowHeight)
        }
        let lastBand = try #require(past.last)
        #expect(lastBand.rect.maxY >= bounds.maxY)
    }

    // NSTableView blends the dark alternate stripe in twice past the last row; the grid blends it once, as a row does.
    @Test("Past the last row the table blends each stripe once, as a row does")
    func stripesPastTheLastRowAreBlendedOnce() throws {
        let grid = makeGrid(columns: ["id", "name"], rows: 1)
        defer { grid.close() }
        let table = grid.main
        table.usesAlternatingRowBackgroundColors = true
        let dark = try #require(NSAppearance(named: .darkAqua))
        let bounds = table.bounds
        let bands = DataGridBodyChrome.rowBands(in: bounds, of: table, tableView: table)
        let oddBand = try #require(bands.first { !$0.isTableRow && !$0.row.isMultiple(of: 2) })

        let rep = try bitmap(width: bounds.width, height: bounds.height)
        try drawFlipped(into: rep, height: bounds.height, appearance: dark) {
            DataGridBodyChrome.drawTableBackground(in: bounds, of: table, scope: .live)
        }

        let sampled = try #require(rep.colorAt(x: 300, y: Int(oddBand.rect.midY))?.usingColorSpace(.sRGB))
        let expected = try #require(singleBlend(over: .controlBackgroundColor, of: oddBand.row, appearance: dark))

        #expect(abs(sampled.redComponent - expected.redComponent) < 0.02, "sampled \(sampled), expected \(expected)")
        #expect(abs(sampled.greenComponent - expected.greenComponent) < 0.02)
        #expect(abs(sampled.blueComponent - expected.blueComponent) < 0.02)
    }

    @Test("Stripes follow the alternating rows setting and the theme's pair")
    func stripeColorFollowsTheSettingAndTheme() {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        #expect(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView, scope: .live) == nil)

        tableView.usesAlternatingRowBackgroundColors = true
        let resolved = ThemeScope.live.resolved
        #expect(DataGridBodyChrome.stripeColor(forRow: 0, of: tableView, scope: .live) == resolved[.gridBackground])
        #expect(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView, scope: .live) == resolved[.gridAlternateRow])
    }

    private func singleBlend(over background: NSColor, of row: Int, appearance: NSAppearance) -> NSColor? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            let pixel = NSRect(x: 0, y: 0, width: 1, height: 1)
            background.setFill()
            pixel.fill()
            let stripes = NSColor.alternatingContentBackgroundColors
            stripes[row % stripes.count].setFill()
            pixel.fill(using: .sourceOver)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
    }
}
