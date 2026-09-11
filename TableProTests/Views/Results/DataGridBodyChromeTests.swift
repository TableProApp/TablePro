//
//  DataGridBodyChromeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class BodyChromeLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// The grid draws its own column separators because `NSTableView` draws vertical grid lines with one
/// separator view per column and re-sorts its whole subview list on every layout pass: 518ms for a
/// single pass on a 500-column result, against 0.03ms with the mask cleared (#2381).
///
/// These measure through `rect(ofColumn:)` and through the rendered pixels, never through the chrome
/// type's own arithmetic, so they cannot pass by agreeing with themselves.
@Suite("Data grid body chrome")
@MainActor
struct DataGridBodyChromeTests {
    private struct Grid {
        let window: NSWindow
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator
    }

    private func makeGrid(columns: [String], rows: Int = 3, width: CGFloat = 600) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: BodyChromeLayoutPersister()
        )
        let queryRows = (0 ..< rows).map { row in
            columns.map { PluginCellValue.text("\($0)-\(row)") }
        }
        let tableRows = TableRows.from(
            queryRows: queryRows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 21
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 120 }
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return Grid(window: window, tableView: tableView, coordinator: coordinator)
    }

    /// Clearing the mask is the fix, so a test that only checked the drawing would pass with the
    /// separator views back and the cost with them. The fixture sets the mask itself, so asserting
    /// on the fixture proves nothing; this reads the one line in the app that decides it.
    @Test("The grid never asks AppKit for vertical grid lines")
    func gridStyleMaskIsClearedInTheAppItself() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TablePro/Views/Results/DataGridView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        #expect(text.contains("gridStyleMask = []"))
        #expect(
            !text.contains("solidVerticalGridLineMask"),
            "one separator view per column costs 518ms of layout per pass on a 500-column result"
        )
    }

    /// A partial repaint invalidates one cell's rect, and `rect(ofColumn:)` includes the intercell
    /// spacing, so the next column's separator lives inside the rect being repainted. It has to be
    /// redrawn there or every visited cell loses its right-hand rule until a full-row repaint.
    @Test("Repainting one cell redraws the separator standing inside its rect")
    func partialRepaintRedrawsTheSeparatorInsideIt() throws {
        let grid = makeGrid(columns: ["id", "name", "total"])
        let view = NSView(frame: grid.tableView.bounds)
        let first = try #require(grid.coordinator.firstPresentedColumnIndex())
        let next = try #require(grid.coordinator.nextPresentedColumnIndex(after: first))
        let cellRect = grid.tableView.rect(ofColumn: first)
        let neighbourSeparator = grid.tableView.rect(ofColumn: next).minX - DataGridBodyChrome.separatorThickness

        #expect(
            neighbourSeparator >= cellRect.minX && neighbourSeparator < cellRect.maxX,
            "the neighbour's separator sits inside the repainted cell's rect, so the repaint erases it"
        )

        let separators = DataGridBodyChrome.separatorRects(
            in: cellRect,
            of: view,
            tableView: grid.tableView,
            presentsColumn: { grid.coordinator.presentsColumn(atTableColumnIndex: $0) }
        )

        #expect(separators.map(\.minX).contains(neighbourSeparator))
    }

    /// AppKit put its separator at the leading edge of every column, which is the boundary the
    /// reader sees between two columns and the one that keeps the row-number column's edge.
    @Test("A separator stands at the leading edge of every presented column")
    func separatorsSitAtPresentedColumnLeadingEdges() {
        let grid = makeGrid(columns: ["id", "name", "total"])
        let view = NSView(frame: grid.tableView.bounds)

        let separators = DataGridBodyChrome.separatorRects(
            in: view.bounds,
            of: view,
            tableView: grid.tableView,
            presentsColumn: { grid.coordinator.presentsColumn(atTableColumnIndex: $0) }
        )

        let expected = grid.tableView.tableColumns.indices
            .filter { grid.coordinator.presentsColumn(atTableColumnIndex: $0) }
            .map { grid.tableView.rect(ofColumn: $0).minX - DataGridBodyChrome.separatorThickness }
        #expect(!expected.isEmpty)
        #expect(separators.map(\.minX) == expected)
        #expect(separators.allSatisfy { $0.width == DataGridBodyChrome.separatorThickness })
    }

    /// The row-number column is an attached column that the result does not present, so it gets no
    /// separator of its own; the boundary the reader sees there is the first data column's edge.
    @Test("The row-number column is not given a separator of its own")
    func rowNumberColumnHasNoSeparator() {
        let grid = makeGrid(columns: ["id", "name"])
        let rowNumber = grid.tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)

        #expect(rowNumber >= 0)
        #expect(!grid.coordinator.presentsColumn(atTableColumnIndex: rowNumber))
    }

    /// The colour has to come from `tableView.gridColor`, which is the dynamic catalog colour AppKit
    /// was filling with, so an appearance change carries the separator with it and there is no
    /// second spelling to keep in sync. A hardcoded colour would pass a geometry test and be wrong
    /// in dark mode.
    @Test("The separator is drawn in the table view's own grid colour")
    func separatorUsesTheTableViewGridColor() throws {
        let grid = makeGrid(columns: ["id", "name"])
        grid.tableView.gridColor = .systemRed
        let rowView = try #require(grid.tableView.rowView(atRow: 0, makeIfNecessary: true) as? DataGridRowView)
        rowView.layoutSubtreeIfNeeded()

        let rep = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: rep)

        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let boundary = grid.tableView.rect(ofColumn: firstData).minX
        let scale = CGFloat(rep.pixelsWide) / rowView.bounds.width
        let sampled = rep.colorAt(
            x: Int((boundary - 0.5) * scale),
            y: Int(rowView.bounds.height * scale / 2)
        )?.usingColorSpace(.deviceRGB)
        let expected = NSColor.systemRed.usingColorSpace(.deviceRGB)

        let sampledRed = try #require(sampled?.redComponent)
        let sampledGreen = try #require(sampled?.greenComponent)
        let expectedRed = try #require(expected?.redComponent)
        #expect(abs(sampledRed - expectedRed) < 0.15)
        #expect(sampledRed > sampledGreen + 0.3, "the separator has to carry the grid colour, not a fixed grey")
    }

    /// `NSTableView` continues the alternation past the last row one row height at a time, numbered
    /// on from it, and the grid now paints those bands itself.
    @Test("Past the last row, bands continue one row apart, numbered on from the last row")
    func bandsContinuePastTheLastRow() throws {
        let grid = makeGrid(columns: ["id", "name"], rows: 3)
        let bounds = grid.tableView.bounds
        let bands = DataGridBodyChrome.rowBands(in: bounds, of: grid.tableView, tableView: grid.tableView)

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
        let lastRowBottom = grid.tableView.rect(ofRow: 2).maxY
        for (offset, band) in past.enumerated() {
            #expect(band.rect.minY == lastRowBottom + CGFloat(offset) * grid.tableView.rowHeight)
            #expect(band.rect.height == grid.tableView.rowHeight)
        }
        let lastBand = try #require(past.last)
        #expect(lastBand.rect.maxY >= bounds.maxY)
    }

    /// `NSTableView` blends the dark alternate stripe in twice past the last row (52 against a row's
    /// 40, measured on screen), so its empty rows read brighter than the rows above them. The grid
    /// paints that area itself, the stripe blended once over the table's colour, which is what a row
    /// shows.
    ///
    /// Measured through the drawing itself rather than a cached drawing of the table: offscreen,
    /// `cacheDisplay` runs a second alternating pass of `NSTableView`'s own that the table never shows
    /// on screen (54 against 41), so a cached table cannot tell the two paintings apart.
    @Test("Past the last row the table blends each stripe once, as a row does")
    func stripesPastTheLastRowAreBlendedOnce() throws {
        let grid = makeGrid(columns: ["id", "name"], rows: 1)
        grid.tableView.usesAlternatingRowBackgroundColors = true
        let dark = try #require(NSAppearance(named: .darkAqua))
        let bounds = grid.tableView.bounds
        let bands = DataGridBodyChrome.rowBands(in: bounds, of: grid.tableView, tableView: grid.tableView)
        let oddBand = try #require(bands.first { !$0.isTableRow && !$0.row.isMultiple(of: 2) })

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width),
            pixelsHigh: Int(bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        dark.performAsCurrentDrawingAppearance {
            DataGridBodyChrome.drawTableBackground(in: bounds, of: grid.tableView)
        }
        NSGraphicsContext.restoreGraphicsState()

        let sampled = try #require(rep.colorAt(x: 300, y: Int(oddBand.rect.midY))?.usingColorSpace(.sRGB))
        let expected = try #require(singleBlend(over: .controlBackgroundColor, of: oddBand.row, appearance: dark))

        #expect(abs(sampled.redComponent - expected.redComponent) < 0.02, "sampled \(sampled), expected \(expected)")
        #expect(abs(sampled.greenComponent - expected.greenComponent) < 0.02)
        #expect(abs(sampled.blueComponent - expected.blueComponent) < 0.02)
    }

    /// A cached drawing of the table cannot show this (see above), so the one line in the app that
    /// decides it is read instead, as `gridStyleMaskIsClearedInTheAppItself` reads its own.
    @Test("The table never hands its background back to NSTableView")
    func tableBackgroundIsTheGridsOwn() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TablePro/Views/Results/KeyHandlingTableView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        #expect(text.contains("DataGridBodyChrome.drawTableBackground(in: clipRect, of: self)"))
        #expect(
            !text.contains("super.drawBackground(inClipRect:"),
            "NSTableView blends the stripe in twice past the last row, which nothing painting it once can match"
        )
    }

    /// The colour of one alternate stripe blended once over `background`, drawn into a single pixel.
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
