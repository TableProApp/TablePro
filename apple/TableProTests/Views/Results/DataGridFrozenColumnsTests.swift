//
//  DataGridFrozenColumnsTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class FrozenLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private struct FrozenRaster {
    let rep: NSBitmapImageRep
    let rect: NSRect
    let isFlipped: Bool

    init?(of view: NSView) {
        rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        self.rep = rep
        isFlipped = view.isFlipped
    }

    private var scale: CGFloat { CGFloat(rep.pixelsWide) / rect.width }

    func color(at point: NSPoint) -> NSColor? {
        pixel(x: Int(((point.x - rect.minX) * scale).rounded(.down)), y: row(for: point.y))
    }

    func inkPixels(in area: NSRect, unlike background: NSColor) -> Int {
        let top = row(for: isFlipped ? area.minY : area.maxY)
        let bottom = row(for: isFlipped ? area.maxY : area.minY)
        let left = Int(((area.minX - rect.minX) * scale).rounded(.down))
        let right = Int(((area.maxX - rect.minX) * scale).rounded(.down))
        var count = 0
        for y in top..<bottom {
            for x in left..<right {
                guard let color = pixel(x: x, y: y) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.05
                    || abs(color.greenComponent - background.greenComponent) > 0.05
                    || abs(color.blueComponent - background.blueComponent) > 0.05 {
                    count += 1
                }
            }
        }
        return count
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

@MainActor
private struct FrozenGrid {
    static let columnWidth: CGFloat = 160

    let window: NSWindow
    let scrollView: NSScrollView
    let tableView: KeyHandlingTableView
    let header: SortableHeaderView
    let band: DataGridRowGutterView
    let coordinator: TableViewCoordinator

    // The first two columns carry a wide value and the rest a narrow one, so the band's frozen area
    // at a scrolled offset shows which column it is drawing.
    init(columns: Int = 20, rows: Int = 30, frozen: Int = 2) {
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FrozenLayoutPersister()
        )
        let titles = (0..<columns).map { "column\($0)" }
        let tableRows = TableRows.from(
            queryRows: (0..<rows).map { _ in
                titles.indices.map { $0 < 2 ? PluginCellValue.text("WWWWWWWW") : PluginCellValue.text("i") }
            },
            columns: titles,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns)
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)

        tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
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

        header = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        header.coordinator = coordinator
        tableView.headerView = header

        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in Self.columnWidth }
        )

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView

        DataGridView.installRowGutter(scrollView: scrollView, tableView: tableView, coordinator: coordinator)
        band = coordinator.rowGutter ?? DataGridRowGutterView(frame: .zero)
        let selectionOverlay = GridSelectionOverlay(frame: tableView.bounds)
        selectionOverlay.tableView = tableView
        selectionOverlay.coordinator = coordinator
        tableView.addSubview(selectionOverlay)
        tableView.selectionOverlay = selectionOverlay
        coordinator.selectionController.tableView = tableView
        coordinator.selectionController.overlay = selectionOverlay
        coordinator.selectionController.coordinator = coordinator

        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        coordinator.frozenColumnCount = frozen
        band.synchronizeGeometry()
        for row in 0..<rows {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
        }
    }

    func dataColumn(_ position: Int) -> Int {
        coordinator.tableColumnIndex(forDisplayPosition: position) ?? -1
    }

    var offset: CGFloat { scrollView.contentView.bounds.minX }

    func scroll(toX x: CGFloat) {
        tableView.scroll(NSPoint(x: x, y: scrollView.contentView.bounds.origin.y))
        scrollView.layoutSubtreeIfNeeded()
    }

    var bandWindowMinX: CGFloat { band.convert(band.bounds, to: nil).minX }

    // Offscreen the floating container sits a header lower than the table, so only rows whose
    // middle the band actually covers are asked about.
    var rowsUnderTheBand: [Int] {
        (0..<tableView.numberOfRows).filter { row in
            let rowRect = band.convert(tableView.rect(ofRow: row), from: tableView)
            return band.bounds.contains(NSPoint(x: 1, y: rowRect.midY))
        }
    }

    func headerMenu(forColumn tableColumnIndex: Int) -> NSMenu {
        let menu = NSMenu()
        coordinator.populateHeaderMenu(menu, forColumnAt: tableColumnIndex)
        return menu
    }
}

@MainActor
struct DataGridFrozenColumnsTests {
    @Test("the band spans the row numbers and the frozen columns, at the leading edge at every offset")
    func bandHoldsTheFrozenColumns() {
        let grid = FrozenGrid()
        let lastFrozen = grid.tableView.rect(ofColumn: grid.dataColumn(1))
        #expect(grid.band.frame.width == lastFrozen.maxX)
        let atOrigin = grid.bandWindowMinX

        for offset in [CGFloat(500), 1_400, 2_600] {
            grid.scroll(toX: offset)
            #expect(grid.offset == offset)
            #expect(grid.bandWindowMinX == atOrigin)
            #expect(grid.band.frame.width == lastFrozen.maxX)
        }
    }

    @Test("a point over the band names the frozen column drawn there")
    func columnAtPointResolvesTheFrozenColumn() {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)
        let first = grid.tableView.rect(ofColumn: grid.dataColumn(0))
        let second = grid.tableView.rect(ofColumn: grid.dataColumn(1))
        let y = grid.tableView.rect(ofRow: 3).midY

        #expect(grid.tableView.column(at: NSPoint(x: grid.offset + first.midX, y: y)) == grid.dataColumn(0))
        #expect(grid.tableView.column(at: NSPoint(x: grid.offset + second.midX, y: y)) == grid.dataColumn(1))

        let pastBand = NSPoint(x: grid.offset + second.maxX + 20, y: y)
        let scrolled = grid.tableView.columnIndexes(in: NSRect(x: pastBand.x, y: y, width: 1, height: 1)).first
        #expect(grid.tableView.column(at: pastBand) == scrolled)
        #expect(grid.tableView.column(at: pastBand) != grid.dataColumn(1))
    }

    @Test("a press on a frozen cell passes through the band to the grid, and the row numbers keep theirs")
    func frozenPressesPassThrough() throws {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)
        let container = try #require(grid.band.superview)
        let row = try #require(grid.rowsUnderTheBand.first)
        let y = grid.band.convert(grid.tableView.rect(ofRow: row), from: grid.tableView).midY
        let frozenX = grid.tableView.rect(ofColumn: grid.dataColumn(0)).midX
        let gutterX = DataGridRowGutterView.width(of: grid.tableView) / 2

        #expect(grid.band.hitTest(grid.band.convert(NSPoint(x: frozenX, y: y), to: container)) == nil)
        #expect(grid.band.hitTest(grid.band.convert(NSPoint(x: gutterX, y: y), to: container)) === grid.band)
    }

    @Test("moving to a frozen column never scrolls; the first scrolling column comes back clear of the band")
    func scrollingToColumnsRespectsTheBand() {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)

        grid.coordinator.scrollColumnToVisible(tableColumnIndex: grid.dataColumn(0))
        #expect(grid.offset == 1_400)

        grid.coordinator.scrollColumnToVisible(tableColumnIndex: grid.dataColumn(2))
        let firstScrolling = grid.tableView.rect(ofColumn: grid.dataColumn(2))
        #expect(firstScrolling.minX >= grid.offset + grid.band.frame.width)
        #expect(grid.offset == 0)
    }

    @Test("a column scrolled under the band is revealed beside it, not under it")
    func columnUnderTheBandIsRevealed() throws {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)
        let bandWidth = grid.band.frame.width
        let hidden = try #require((2..<20).map(grid.dataColumn).first { index in
            let rect = grid.tableView.rect(ofColumn: index)
            return rect.minX >= grid.offset && rect.minX < grid.offset + bandWidth
        })

        grid.coordinator.scrollColumnToVisible(tableColumnIndex: hidden)

        #expect(grid.tableView.rect(ofColumn: hidden).minX == grid.offset + bandWidth)
    }

    @Test("frozen columns too wide for the viewport scroll like the rest")
    func columnsThatDoNotFitAreNotPinned() {
        let grid = FrozenGrid(frozen: 3)
        let band = grid.coordinator.pinnedBand()
        #expect(!band.isFreezing)
        #expect(band.width == DataGridRowGutterView.width(of: grid.tableView))
        #expect(grid.band.frame.width == band.width)

        grid.scroll(toX: 1_400)
        let point = NSPoint(x: grid.offset + band.width + 10, y: grid.tableView.rect(ofRow: 2).midY)
        let natural = grid.tableView.columnIndexes(in: NSRect(x: point.x, y: point.y, width: 1, height: 1)).first
        #expect(grid.tableView.column(at: point) == natural)
    }

    // Scrolled so a scrolling column starts at the gutter's edge, so no separator crosses the area.
    private func inkInFrozenArea(of grid: FrozenGrid) throws -> Int {
        let gutterWidth = DataGridRowGutterView.width(of: grid.tableView)
        grid.scroll(toX: grid.tableView.rect(ofColumn: grid.dataColumn(9)).minX - gutterWidth)
        grid.band.synchronizeGeometry()
        let row = try #require(grid.rowsUnderTheBand.dropFirst().first, "no row under the band")
        let rowRect = grid.scrollView.convert(grid.tableView.rect(ofRow: row), from: grid.tableView)
        let raster = try #require(FrozenRaster(of: grid.scrollView), "the scroll view did not rasterise")
        let background = try #require(
            raster.color(at: NSPoint(x: gutterWidth + 2, y: rowRect.midY)),
            "no pixel at the cell's leading edge"
        )
        let text = NSRect(x: gutterWidth + 4, y: rowRect.minY + 2, width: 80, height: rowRect.height - 4)
        return raster.inkPixels(in: text, unlike: background)
    }

    @Test("scrolled sideways, the band draws the frozen column's value over the column scrolled underneath")
    func bandDrawsTheFrozenCells() throws {
        let frozenInk = try inkInFrozenArea(of: FrozenGrid(frozen: 2))
        let unfrozenInk = try inkInFrozenArea(of: FrozenGrid(frozen: 0))
        #expect(frozenInk > 0)
        #expect(frozenInk > unfrozenInk * 3, "frozen \(frozenInk), scrolled \(unfrozenInk)")
    }

    @Test("the header resolves and places a pinned heading where the band shows it")
    func headerResolvesPinnedHeadings() {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)
        let headerOffset = grid.header.visibleRect.minX
        let first = grid.header.headerRect(ofColumn: grid.dataColumn(0))

        #expect(grid.header.displayedColumn(at: NSPoint(x: headerOffset + first.midX, y: 5)) == grid.dataColumn(0))
        #expect(grid.header.displayedHeaderRect(ofColumn: grid.dataColumn(0)).minX == headerOffset + first.minX)
        #expect(grid.header.frozenHeadingColumn(at: NSPoint(x: headerOffset + grid.band.frame.width + 20, y: 5)) == nil)
    }

    @Test("a frozen cell's popover and editor anchor where the band shows the cell")
    func frozenCellGeometryFollowsTheBand() throws {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)
        let column = grid.dataColumn(0)
        let natural = grid.tableView.rect(ofColumn: column)

        #expect(grid.coordinator.displayedRect(ofColumn: column).minX == grid.offset + natural.minX)
        #expect(grid.coordinator.cellRect(row: 2, tableColumnIndex: column).minX == grid.offset + natural.minX)
        let scrolling = grid.dataColumn(5)
        #expect(grid.coordinator.displayedRect(ofColumn: scrolling) == grid.tableView.rect(ofColumn: scrolling))
    }

    static func floatingContainerIsScrollViewChild() -> Bool {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        scrollView.documentView = document
        let floating = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 800))
        document.addSubview(floating)
        scrollView.addFloatingSubview(floating, for: .horizontal)
        return floating.superview?.superview === scrollView
    }

    @Test(
        "the inline editor of a frozen cell opens over the band, not under it",
        .enabled("AppKit keeps floating subviews in a container under the scroll view") {
            await DataGridFrozenColumnsTests.floatingContainerIsScrollViewChild()
        }
    )
    func editorOpensAboveTheBand() throws {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)
        let column = grid.dataColumn(0)
        let editor = CellOverlayEditor()
        editor.show(in: grid.tableView, row: 2, column: column, columnIndex: 0, value: "value")
        defer { editor.dismiss(commit: false) }

        let container = try #require(editor.containerView)
        let bandContainer = try #require(grid.band.superview)
        let subviews = grid.scrollView.subviews
        let editorIndex = try #require(subviews.firstIndex { $0 === container })
        let bandIndex = try #require(subviews.firstIndex { $0 === bandContainer })
        #expect(editorIndex > bandIndex)

        let cell = CellOverlayBase.displayedCellFrame(in: grid.tableView, column: column, row: 2)
        #expect(container.frame.minX == grid.scrollView.convert(cell, from: grid.tableView).minX)
        #expect(cell.minX == grid.offset + grid.tableView.frameOfCell(atColumn: column, row: 2).minX)
    }

    @Test(
        "a scrolling cell's editor stays under the band",
        .enabled("AppKit keeps floating subviews in a container under the scroll view") {
            await DataGridFrozenColumnsTests.floatingContainerIsScrollViewChild()
        }
    )
    func scrollingEditorStaysUnderTheBand() throws {
        let grid = FrozenGrid()
        grid.scroll(toX: 1_400)
        let column = try #require((2..<20).map(grid.dataColumn).first { index in
            grid.tableView.rect(ofColumn: index).minX >= grid.offset + grid.band.frame.width
        })
        let editor = CellOverlayEditor()
        editor.show(in: grid.tableView, row: 2, column: column, columnIndex: 0, value: "value")
        defer { editor.dismiss(commit: false) }

        let container = try #require(editor.containerView)
        let bandContainer = try #require(grid.band.superview)
        let subviews = grid.scrollView.subviews
        let editorIndex = try #require(subviews.firstIndex { $0 === container })
        let bandIndex = try #require(subviews.firstIndex { $0 === bandContainer })
        #expect(editorIndex < bandIndex)
    }

    @Test("the header menu freezes through the chosen column and unfreezes, reporting each to the owner")
    func headerMenuFreezesAndUnfreezes() throws {
        let grid = FrozenGrid(frozen: 0)
        var reported: [ColumnLayoutState] = []
        grid.coordinator.onColumnLayoutDidChange = { reported.append($0) }
        let freezeTitle = String(localized: "Freeze Up to This Column")
        let unfreezeTitle = String(localized: "Unfreeze Columns")

        let menu = grid.headerMenu(forColumn: grid.dataColumn(1))
        #expect(menu.items.contains { $0.title == unfreezeTitle } == false)
        let freeze = try #require(menu.items.first { $0.title == freezeTitle })
        #expect(freeze.action != nil)
        grid.coordinator.freezeColumnsFromHeaderMenu(freeze)

        #expect(grid.coordinator.frozenColumnCount == 2)
        #expect(reported.last?.frozenColumnCount == 2)

        let frozenMenu = grid.headerMenu(forColumn: grid.dataColumn(1))
        #expect(frozenMenu.items.contains { $0.title == freezeTitle } == false)
        #expect(frozenMenu.items.contains { $0.title == unfreezeTitle })
        grid.coordinator.unfreezeColumnsFromHeaderMenu()

        #expect(grid.coordinator.frozenColumnCount == 0)
        #expect(reported.last?.frozenColumnCount == 0)
    }

    @Test("freezing more than the viewport can hold is offered disabled")
    func freezeThatWouldNotFitIsDisabled() throws {
        let grid = FrozenGrid(frozen: 0)
        let menu = grid.headerMenu(forColumn: grid.dataColumn(4))
        let freeze = try #require(menu.items.first { $0.title == String(localized: "Freeze Up to This Column") })
        #expect(freeze.action == nil)
    }

    @Test("a query grid keeps a layout that only freezes columns")
    func savedLayoutKeepsAFreezeAlone() throws {
        let grid = FrozenGrid()
        var binding = ColumnLayoutState()
        binding.frozenColumnCount = 2
        let saved = try #require(grid.coordinator.savedColumnLayout(binding: binding))
        #expect(saved.frozenColumnCount == 2)
        #expect(grid.coordinator.captureColumnLayout()?.frozenColumnCount == 2)
    }
}

struct DataGridPinnedBandTests {
    @Test("frozen columns pin while they cover at most two thirds of the viewport")
    func fitRule() {
        let fits = DataGridPinnedBand.resolve(
            gutterWidth: 40, frozenColumns: [1, 2], frozenTrailingEdge: 400, viewportWidth: 600, offset: 0
        )
        #expect(fits.isFreezing)
        #expect(fits.width == 400)

        let tooWide = DataGridPinnedBand.resolve(
            gutterWidth: 40, frozenColumns: [1, 2], frozenTrailingEdge: 401, viewportWidth: 600, offset: 0
        )
        #expect(!tooWide.isFreezing)
        #expect(tooWide.width == 40)
    }

    @Test("a frozen column shows at its home moved by the offset, and band points map back")
    func displayedGeometry() {
        let band = DataGridPinnedBand.resolve(
            gutterWidth: 40, frozenColumns: [1], frozenTrailingEdge: 200, viewportWidth: 900, offset: 500
        )
        let home = NSRect(x: 41, y: 0, width: 159, height: 22)
        #expect(band.displayed(home, ofColumn: 1).minX == 541)
        #expect(band.displayed(home, ofColumn: 2).minX == 41)
        #expect(band.unscrolledPoint(NSPoint(x: 560, y: 4)) == NSPoint(x: 60, y: 4))
        #expect(band.unscrolledPoint(NSPoint(x: 700, y: 4)) == nil)
        #expect(band.unscrolledPoint(NSPoint(x: 499, y: 4)) == nil)
    }

    @Test("nothing frozen maps no point")
    func emptyBandMapsNothing() {
        let band = DataGridPinnedBand.resolve(
            gutterWidth: 40, frozenColumns: [], frozenTrailingEdge: 0, viewportWidth: 900, offset: 500
        )
        #expect(!band.isFreezing)
        #expect(band.unscrolledPoint(NSPoint(x: 510, y: 4)) == nil)
    }
}
