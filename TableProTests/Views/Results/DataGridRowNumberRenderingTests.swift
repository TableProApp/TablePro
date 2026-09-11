//
//  DataGridRowNumberRenderingTests.swift
//  TableProTests
//
//  The row-number column is pinned by a floating strip over the rows and by a heading the header
//  view draws itself. These rasterise both and hold them to the columns beside them, never to their
//  own arithmetic: one line at the edge, the same background, nothing scrolled showing through.
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class RowNumberLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// One view's cached drawing, read back by point.
@MainActor
private struct Raster {
    let rep: NSBitmapImageRep
    let rect: NSRect
    let isFlipped: Bool

    init?(of view: NSView, in rect: NSRect) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        self.rep = rep
        self.rect = rect
        isFlipped = view.isFlipped
    }

    var scale: CGFloat { CGFloat(rep.pixelsWide) / rect.width }

    func color(at point: NSPoint) -> NSColor? {
        pixel(x: column(for: point.x), y: row(for: point.y))
    }

    /// Every pixel along one horizontal line, from `minX` up to `maxX`.
    func colors(fromX minX: CGFloat, toX maxX: CGFloat, atY y: CGFloat) -> [NSColor] {
        let row = row(for: y)
        return (column(for: minX)..<column(for: maxX)).compactMap { pixel(x: $0, y: row) }
    }

    /// How many pixels inside `area` differ from `background`.
    func inkPixels(in area: NSRect, unlike background: NSColor) -> Int {
        let rows = row(for: isFlipped ? area.minY : area.maxY)..<row(for: isFlipped ? area.maxY : area.minY)
        let columns = column(for: area.minX)..<column(for: area.maxX)
        return rows.reduce(0) { count, row in
            count + columns.filter { column in
                pixel(x: column, y: row).map { !matches($0, background) } ?? false
            }.count
        }
    }

    private func column(for x: CGFloat) -> Int {
        Int(((x - rect.minX) * scale).rounded(.down))
    }

    private func row(for y: CGFloat) -> Int {
        let fromTop = isFlipped ? y - rect.minY : rect.maxY - y
        return Int((fromTop * scale).rounded(.down))
    }

    private func pixel(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }
}

private func matches(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
    abs(lhs.redComponent - rhs.redComponent) <= tolerance
        && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
        && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
        && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
}

@Suite("Pinned row-number column rendering", .serialized)
@MainActor
struct DataGridRowNumberRenderingTests {
    @MainActor
    private struct Grid {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: KeyHandlingTableView
        let header: SortableHeaderView
        let gutter: DataGridRowGutterView
        let coordinator: TableViewCoordinator

        var rowNumberColumn: Int {
            tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        }

        /// Through `scroll(_:)`, which moves the header with the rows.
        func scroll(toX x: CGFloat) {
            tableView.scroll(NSPoint(x: x, y: scrollView.contentView.bounds.origin.y))
            scrollView.layoutSubtreeIfNeeded()
        }

        func pointInScrollView(_ point: NSPoint) -> NSPoint {
            scrollView.convert(point, from: tableView)
        }

        /// The rows whose middle the strip covers.
        ///
        /// Offscreen, the floating container sits a header's height lower than the table (its
        /// bounds follow the clip view while its frame starts below the header), so the strip
        /// misses the first row or two here where on screen it covers them. Asking the geometry
        /// keeps every check on a row the strip actually paints, instead of passing by comparing a
        /// row with itself.
        var rowsUnderTheStrip: [Int] {
            (0..<tableView.numberOfRows).filter { row in
                let band = gutter.convert(tableView.rect(ofRow: row), from: tableView)
                return gutter.bounds.contains(NSPoint(x: 1, y: band.midY))
            }
        }
    }

    private static let columnWidth: CGFloat = 160
    private static let rowCount = 12

    private func makeGrid(
        titles: [String] = (0..<8).map { "column\($0)" },
        rows: Int = DataGridRowNumberRenderingTests.rowCount,
        appearance: NSAppearance.Name = .darkAqua
    ) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: RowNumberLayoutPersister()
        )
        let columnTypes = Array(repeating: ColumnType.text(rawType: "TEXT"), count: titles.count)
        let tableRows = TableRows.from(
            queryRows: (0..<rows).map { _ in titles.map { _ in PluginCellValue.text("x") } },
            columns: titles,
            columnTypes: columnTypes
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = true
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.updateCache()

        let header = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        header.coordinator = coordinator
        tableView.headerView = header

        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in Self.columnWidth }
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = scrollView

        let gutter = DataGridRowGutterView(frame: .zero)
        gutter.coordinator = coordinator
        tableView.addSubview(gutter)
        scrollView.addFloatingSubview(gutter, for: .horizontal)
        coordinator.rowGutter = gutter

        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        gutter.synchronizeGeometry()
        for row in 0..<rows {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
        }
        return Grid(
            window: window,
            scrollView: scrollView,
            tableView: tableView,
            header: header,
            gutter: gutter,
            coordinator: coordinator
        )
    }

    // MARK: - The pinned rows

    /// In dark mode the alternate stripe is white at under 5% alpha, so a strip filled with it alone
    /// let the columns scrolled under it show through every other row.
    @Test("The strip is opaque on every row it pins")
    func stripIsOpaqueOnEveryRow() throws {
        let grid = makeGrid(appearance: .darkAqua)
        let rows = grid.rowsUnderTheStrip
        #expect(rows.count >= 6, "too few rows under the strip to cover both stripes")
        let raster = try #require(Raster(of: grid.gutter, in: grid.gutter.bounds))

        for row in rows {
            let rowRect = grid.gutter.convert(grid.tableView.rect(ofRow: row), from: grid.tableView)
            let color = try #require(raster.color(at: NSPoint(x: 2, y: rowRect.midY)))
            #expect(color.alphaComponent > 0.99, "row \(row) is see-through")
        }
    }

    /// Light mode, where every colour a row paints is opaque, so the cached drawing composites as the
    /// screen does and the strip can be held pixel for pixel to the row beside it.
    @Test("At scroll offset zero the strip shows the row it covers, stripe and selection alike")
    func stripMatchesTheRowsItCovers() throws {
        let grid = makeGrid(appearance: .aqua)
        let rows = grid.rowsUnderTheStrip
        #expect(rows.count >= 6, "too few rows under the strip to cover both stripes and a selection")
        let selected = try #require(rows.dropFirst(2).first)
        grid.tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let dataRect = grid.tableView.rect(ofColumn: firstData)
        let raster = try #require(Raster(of: grid.scrollView, in: grid.scrollView.bounds))

        for row in rows {
            let midY = grid.tableView.rect(ofRow: row).midY
            let strip = try #require(raster.color(at: grid.pointInScrollView(NSPoint(x: 2, y: midY))))
            let body = try #require(
                raster.color(at: grid.pointInScrollView(NSPoint(x: dataRect.maxX - 12, y: midY)))
            )
            #expect(matches(strip, body), "row \(row): strip \(strip), row \(body)")
        }
    }

    /// The strip used to be the column's width and draw its own line a point short of the grid's, so
    /// two translucent lines stood side by side.
    @Test("Exactly one line stands between the row numbers and the first data column")
    func oneLineAtTheStripEdge() throws {
        let grid = makeGrid(appearance: .darkAqua)
        let edge = grid.tableView.rect(ofColumn: grid.rowNumberColumn).maxX
        let row = try #require(grid.rowsUnderTheStrip.first { $0.isMultiple(of: 2) })
        let midY = grid.tableView.rect(ofRow: row).midY
        let raster = try #require(Raster(of: grid.scrollView, in: grid.scrollView.bounds))
        let background = try #require(raster.color(at: grid.pointInScrollView(NSPoint(x: 2, y: midY))))

        let from = grid.pointInScrollView(NSPoint(x: edge - 3, y: midY))
        let to = grid.pointInScrollView(NSPoint(x: edge + 2, y: midY))
        let linePixels = raster.colors(fromX: from.x, toX: to.x, atY: from.y).filter { !matches($0, background) }

        #expect(!linePixels.isEmpty, "the edge has no line at all")
        #expect(
            CGFloat(linePixels.count) <= raster.scale * DataGridBodyChrome.separatorThickness,
            "\(linePixels.count) pixels of line at \(raster.scale)x"
        )
    }

    /// Scrolled sideways, the grid's own separator has gone under the strip, so the strip's edge is the
    /// only line left there. A strip one point short draws none, and the numbers lose their edge.
    @Test("Scrolled sideways, exactly one line stands at the pinned strip's edge")
    func oneLineAtThePinnedEdgeWhenScrolled() throws {
        let grid = makeGrid(appearance: .darkAqua)
        let row = try #require(grid.rowsUnderTheStrip.first { $0.isMultiple(of: 2) })
        grid.scroll(toX: 70)
        let raster = try #require(Raster(of: grid.scrollView, in: grid.scrollView.bounds))

        let stripMinX = grid.scrollView.convert(NSPoint.zero, from: grid.gutter).x
        let edge = stripMinX + grid.tableView.rect(ofColumn: grid.rowNumberColumn).width
        let y = grid.pointInScrollView(NSPoint(x: 0, y: grid.tableView.rect(ofRow: row).midY)).y
        let background = try #require(raster.color(at: NSPoint(x: stripMinX + 2, y: y)))
        let linePixels = raster.colors(fromX: edge - 3, toX: edge + 2, atY: y).filter { !matches($0, background) }

        #expect(!linePixels.isEmpty, "the pinned strip has no edge")
        #expect(
            CGFloat(linePixels.count) <= raster.scale * DataGridBodyChrome.separatorThickness,
            "\(linePixels.count) pixels of line at \(raster.scale)x"
        )
    }

    // MARK: - Past the last row

    /// The columns scroll under the strip past the last row too, where it used to paint nothing and
    /// let every column line crossing that area show through the numbers' column.
    @Test("Past the last row the strip is opaque")
    func stripIsOpaquePastTheLastRow() throws {
        let grid = makeGrid(rows: 3)
        let lastRow = grid.gutter.convert(grid.tableView.rect(ofRow: 2), from: grid.tableView)
        let below = NSPoint(x: 2, y: lastRow.maxY + grid.tableView.rowHeight * 1.5)
        #expect(grid.gutter.bounds.contains(below))
        let raster = try #require(Raster(of: grid.gutter, in: grid.gutter.bounds))

        let color = try #require(raster.color(at: below))
        #expect(color.alphaComponent > 0.99, "past the last row the strip is see-through")
    }

    @Test("Scrolled sideways, no column line shows through the strip past the last row")
    func noColumnLineShowsThroughPastTheLastRow() throws {
        let grid = makeGrid(rows: 3)
        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let secondData = try #require(grid.coordinator.nextPresentedColumnIndex(after: firstData))
        grid.scroll(toX: grid.tableView.rect(ofColumn: secondData).minX - 20)
        let raster = try #require(Raster(of: grid.scrollView, in: grid.scrollView.bounds))

        let pastLastRow = grid.tableView.rect(ofRow: 2).maxY + grid.tableView.rowHeight * 1.5
        let stripMinX = grid.scrollView.convert(NSPoint.zero, from: grid.gutter).x
        let stripWidth = grid.tableView.rect(ofColumn: grid.rowNumberColumn).width
        let y = grid.pointInScrollView(NSPoint(x: 0, y: pastLastRow)).y
        let background = try #require(raster.color(at: NSPoint(x: stripMinX + 2, y: y)))
        let strayPixels = raster.colors(fromX: stripMinX + 1, toX: stripMinX + stripWidth - 3, atY: y)
            .filter { !matches($0, background) }

        #expect(strayPixels.isEmpty, "\(strayPixels.count) pixels of a scrolled column line inside the strip")
    }

    // MARK: - The pinned heading

    @Test("Scrolled sideways, the pinned heading holds the visible leading edge at its column's width")
    func pinnedHeadingHoldsTheLeadingEdge() throws {
        let grid = makeGrid()
        grid.scroll(toX: 300)
        let pinned = try #require(grid.header.pinnedRowNumberHeadingRect)

        #expect(pinned.minX == grid.scrollView.contentView.bounds.minX)
        #expect(pinned.width == grid.header.headerRect(ofColumn: grid.rowNumberColumn).width)
    }

    @Test("The pinned heading draws its title where the column scrolled under it would show")
    func pinnedHeadingDrawsItsTitle() throws {
        let grid = makeGrid()
        grid.scroll(toX: 300)
        let pinned = try #require(grid.header.pinnedRowNumberHeadingRect)
        let raster = try #require(Raster(of: grid.header, in: grid.header.visibleRect))
        let background = try #require(raster.color(at: NSPoint(x: pinned.minX + 2, y: pinned.minY + 3)))

        let titleArea = NSRect(x: pinned.maxX - 16, y: pinned.midY - 5, width: 13, height: 10)
        #expect(raster.inkPixels(in: titleArea, unlike: background) > 0)
    }

    @Test("The pinned heading paints the same background as the headings beside it")
    func pinnedHeadingMatchesItsNeighbours() throws {
        let grid = makeGrid()
        grid.scroll(toX: 300)
        let pinned = try #require(grid.header.pinnedRowNumberHeadingRect)
        let neighbour = grid.header.headerRect(
            ofColumn: grid.header.column(at: NSPoint(x: pinned.maxX + 60, y: pinned.midY))
        )
        let raster = try #require(Raster(of: grid.header, in: grid.header.visibleRect))

        let strip = try #require(raster.color(at: NSPoint(x: pinned.minX + 2, y: pinned.midY)))
        let beside = try #require(raster.color(at: NSPoint(x: neighbour.maxX - 8, y: pinned.midY)))
        #expect(matches(strip, beside), "pinned \(strip), beside \(beside)")
    }

    @Test("No heading scrolled under the pinned heading shows through it")
    func scrolledHeadingsDoNotShowThrough() throws {
        let grid = makeGrid(titles: (0..<8).map { "WWWWWWWWWWWWWWWWWWWW\($0)" })
        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let secondData = try #require(grid.coordinator.nextPresentedColumnIndex(after: firstData))
        grid.scroll(toX: grid.header.headerRect(ofColumn: secondData).minX)
        let pinned = try #require(grid.header.pinnedRowNumberHeadingRect)
        let raster = try #require(Raster(of: grid.header, in: grid.header.visibleRect))
        let background = try #require(raster.color(at: NSPoint(x: pinned.minX + 2, y: pinned.minY + 3)))

        let underTheTitle = NSRect(x: pinned.minX + 1, y: pinned.minY + 4, width: pinned.width - 18, height: pinned.height - 8)
        #expect(raster.inkPixels(in: underTheTitle, unlike: background) == 0)
    }

    @Test("Exactly one divider stands at the pinned heading's trailing edge")
    func oneDividerAtThePinnedHeadingEdge() throws {
        let grid = makeGrid()
        grid.scroll(toX: 300)
        let pinned = try #require(grid.header.pinnedRowNumberHeadingRect)
        let raster = try #require(Raster(of: grid.header, in: grid.header.visibleRect))
        let background = try #require(raster.color(at: NSPoint(x: pinned.minX + 2, y: pinned.midY)))

        let dividerPixels = raster.colors(fromX: pinned.maxX - 3, toX: pinned.maxX + 3, atY: pinned.midY)
            .filter { !matches($0, background) }
        #expect(!dividerPixels.isEmpty, "the pinned heading has no divider")
        #expect(
            CGFloat(dividerPixels.count) <= raster.scale * SortableHeaderChrome.separatorThickness,
            "\(dividerPixels.count) pixels of divider at \(raster.scale)x"
        )
    }

    @Test("A column edge scrolled under the pinned heading is not a resize zone")
    func edgesUnderThePinnedHeadingAreNotResizeZones() throws {
        let grid = makeGrid()
        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let edge = grid.header.headerRect(ofColumn: firstData).maxX
        let point = NSPoint(x: edge, y: grid.header.bounds.midY)
        #expect(grid.header.isInResizeZone(point: point))

        grid.scroll(toX: edge - 20)

        #expect(grid.header.isInPinnedRowNumberHeading(point))
        #expect(!grid.header.isInResizeZone(point: point))
    }

    @Test("Right-clicking the pinned heading offers no menu for the column scrolled under it")
    func pinnedHeadingOffersNoColumnMenu() throws {
        let grid = makeGrid()
        grid.header.menu = NSMenu()
        grid.scroll(toX: 300)
        let pinned = try #require(grid.header.pinnedRowNumberHeadingRect)

        let inside = try #require(rightClick(at: NSPoint(x: pinned.midX, y: pinned.midY), in: grid))
        let beside = try #require(rightClick(at: NSPoint(x: pinned.maxX + 60, y: pinned.midY), in: grid))

        #expect(grid.header.menu(for: inside) == nil)
        #expect(grid.header.menu(for: beside) != nil)
    }

    /// The heading is painted without a scroll too, when the row-number column widens for a longer
    /// number. A scroll then has to clear it from where it was painted, not from where a previous
    /// scroll left it, or a stale copy stays behind over the heading underneath.
    @Test("The pinned heading records where it was painted, including after the column widens")
    func pinnedHeadingRecordsWhereItWasPainted() throws {
        let grid = makeGrid()
        grid.scroll(toX: 300)
        _ = Raster(of: grid.header, in: grid.header.visibleRect)
        #expect(grid.header.drawnPinnedHeadingRect == grid.header.pinnedRowNumberHeadingRect)

        let column = grid.tableView.tableColumns[grid.rowNumberColumn]
        DataGridView.sizeRowNumberColumn(column, forMaxRowNumber: 10_000_000)
        let widened = try #require(grid.header.pinnedRowNumberHeadingRect)
        _ = Raster(of: grid.header, in: grid.header.visibleRect)

        #expect(grid.header.drawnPinnedHeadingRect == widened)
    }

    /// `NSTableRowView` paints the system stripes whatever the table is told, so a theme's own pair
    /// only shows because the row paints the stripe `DataGridBodyChrome` gives it. The strip reads the
    /// same owner, so it has to keep matching the row under a theme too. Light mode, where the
    /// system stripes are white and light grey, so a dark themed row cannot pass for one.
    @Test("Rows paint the theme's stripes, and the strip still matches them")
    func rowsPaintTheThemesStripes() throws {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        defer { engine.activateTheme(original) }
        var theme = ThemeDefinition.default
        theme.id = "test.grid-stripes"
        theme.dataGrid.background = "#282A36"
        theme.dataGrid.alternateRow = "#44475A"
        engine.activateTheme(theme)

        let grid = makeGrid(appearance: .aqua)
        let rows = grid.rowsUnderTheStrip
        #expect(rows.count >= 4, "too few rows under the strip to cover both stripes")
        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let dataRect = grid.tableView.rect(ofColumn: firstData)
        let raster = try #require(Raster(of: grid.scrollView, in: grid.scrollView.bounds))

        var bodies: [Int: NSColor] = [:]
        for row in rows {
            let midY = grid.tableView.rect(ofRow: row).midY
            let strip = try #require(raster.color(at: grid.pointInScrollView(NSPoint(x: 2, y: midY))))
            let body = try #require(
                raster.color(at: grid.pointInScrollView(NSPoint(x: dataRect.maxX - 12, y: midY)))
            )
            #expect(matches(strip, body), "row \(row): strip \(strip), row \(body)")
            #expect(body.redComponent < 0.35, "row \(row) drew \(body), not the theme's dark stripe")
            bodies[row] = body
        }
        let even = try #require(rows.first(where: { $0.isMultiple(of: 2) }).flatMap { bodies[$0] })
        let odd = try #require(rows.first(where: { !$0.isMultiple(of: 2) }).flatMap { bodies[$0] })
        #expect(!matches(even, odd), "both stripes drew \(even)")
    }

    private func rightClick(at point: NSPoint, in grid: Grid) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: grid.header.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: grid.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}
