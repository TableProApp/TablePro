//
//  DataGridFittingHeightTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class RecordingPageScrollView: NSScrollView {
    private(set) var wheelEvents: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) {
        wheelEvents.append(event)
    }
}

@MainActor
private final class FlippedPageDocument: NSView {
    override var isFlipped: Bool { true }
}

// A fitsRows grid laid on a page that scrolls vertically, sized the way DataGridView sizes it.
@MainActor
private final class PagedGrid {
    let grid: HostedDataGrid
    let page = RecordingPageScrollView(frame: .zero)
    private let document = FlippedPageDocument(frame: .zero)
    private let gridTop: CGFloat

    init(rows: TableRows, gridTop: CGFloat = 0) {
        var configuration = DataGridConfiguration()
        configuration.fitsRows = true
        grid = HostedDataGrid(rows: rows, configuration: configuration)
        self.gridTop = gridTop
        page.hasVerticalScroller = true
        page.documentView = document
        let gridView = grid.controller.view
        gridView.removeFromSuperview()
        gridView.autoresizingMask = []
        document.addSubview(gridView)
        grid.window.contentView = page
        fit()
    }

    // What SwiftUI does with the published height, applied now.
    func fit() {
        for _ in 0..<2 {
            let height = grid.controller.measuredFittingHeight
            grid.controller.view.frame = NSRect(x: 0, y: gridTop, width: page.bounds.width, height: height)
            document.frame = NSRect(x: 0, y: 0, width: page.bounds.width, height: gridTop + height + page.bounds.height)
            grid.layout()
        }
    }

    func rowRectOnPage(_ row: Int) -> NSRect {
        document.convert(grid.main.rect(ofRow: row), from: grid.main)
    }

    func showsOnPage(row: Int) -> Bool {
        let rect = rowRectOnPage(row)
        let visible = page.documentVisibleRect
        return rect.minY >= visible.minY - 0.5 && rect.maxY <= visible.maxY + 0.5
    }

    var gridOffset: CGFloat {
        grid.mainScrollView.contentView.bounds.origin.y + grid.controller.headerInset
    }

    func close() {
        grid.close()
    }
}

@MainActor
struct DataGridFittingHeightTests {
    private static var fitsRows: DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.fitsRows = true
        return configuration
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private struct WheelStep {
        var phase: NSEvent.Phase = []
        var momentum: NSEvent.Phase = []
        var dx: CGFloat = 0
        var dy: CGFloat = 0
    }

    private static func routedAxes(_ steps: [WheelStep]) -> [DataGridWheelRouting.Axis] {
        var routing = DataGridWheelRouting()
        return steps.map { routing.axis(phase: $0.phase, momentumPhase: $0.momentum, deltaX: $0.dx, deltaY: $0.dy) }
    }

    private func wheel(dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if let momentum {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        }
        return try #require(NSEvent(cgEvent: event))
    }

    // MARK: - Height

    @Test("A grid is as tall as its header and rows")
    func heightIsHeaderPlusRows() {
        let height = DataGridMetrics.fittingHeight(headerHeight: 28, rowCount: 5, rowPitch: 24, horizontalScrollerHeight: 0)

        #expect(height == 148)
    }

    @Test("A legacy horizontal scroller adds its height below the rows")
    func legacyScrollerAddsItsHeight() {
        let height = DataGridMetrics.fittingHeight(headerHeight: 28, rowCount: 5, rowPitch: 24, horizontalScrollerHeight: 15)

        #expect(height == 163)
    }

    @Test("A grid with no rows is as tall as its header")
    func emptyGridIsItsHeader() {
        #expect(DataGridMetrics.fittingHeight(headerHeight: 28, rowCount: 0, rowPitch: 24, horizontalScrollerHeight: 0) == 28)
        #expect(DataGridMetrics.fittingHeight(headerHeight: 28, rowCount: -1, rowPitch: 24, horizontalScrollerHeight: 0) == 28)
    }

    @Test("A grid scrolls vertically itself unless it is told to fit its rows")
    func fitsRowsIsOffByDefault() {
        #expect(!DataGridConfiguration().fitsRows)
    }

    @Test("A grid that fits its rows publishes their height and follows inserts and removes")
    func publishedHeightFollowsTheRows() async throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: Self.fitsRows)
        defer { grid.close() }
        let pitch = grid.main.rowHeight + grid.main.intercellSpacing.height
        let header = try #require(grid.main.headerView).frame.height

        try await waitUntil { grid.model.fittingHeight == header + 5 * pitch + grid.mainScrollView.legacyHorizontalScrollerHeight }
        let fiveRows = grid.model.fittingHeight

        grid.model.apply(grid.owner.tableRows.appendInsertedRow(values: [.text("5"), .text("fay"), .text("29")]))
        try await waitUntil { grid.model.fittingHeight == fiveRows + pitch }

        grid.model.apply(grid.owner.tableRows.remove(rowIDs: [.existing(0), .existing(1)]))
        try await waitUntil { grid.model.fittingHeight == fiveRows - pitch }
    }

    @Test("A grid that fits its rows drops its vertical scroller and bounce and keeps its horizontal scroll")
    func fitsRowsScrollsOnlySideways() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: Self.fitsRows)
        defer { grid.close() }

        #expect(!grid.mainScrollView.hasVerticalScroller)
        #expect(grid.mainScrollView.verticalScrollElasticity == .none)
        #expect(grid.mainScrollView.hasHorizontalScroller)
        #expect(grid.mainScrollView.horizontalScrollElasticity != .none)
    }

    @Test("A grid that scrolls itself keeps its scrollers and never publishes a height")
    func defaultGridIsUnchanged() async {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        await nextMainTurn()

        #expect(grid.mainScrollView.hasVerticalScroller)
        #expect(grid.mainScrollView.verticalScrollElasticity == .automatic)
        #expect(grid.model.fittingHeight == 0)
    }

    @Test("Turning fitsRows on for a mounted grid removes its vertical scroller and publishes its height")
    func turningFitsRowsOnApplies() async throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        grid.model.configuration.fitsRows = true

        #expect(!grid.mainScrollView.hasVerticalScroller)
        try await waitUntil { grid.model.fittingHeight == grid.controller.measuredFittingHeight }
        #expect(grid.model.fittingHeight > 0)
    }

    // MARK: - Wheel axis

    @Test("A mouse wheel decides its axis notch by notch")
    func mouseWheelDecidesPerEvent() {
        let axes = Self.routedAxes([
            WheelStep(dy: -10),
            WheelStep(dx: 12, dy: 1),
            WheelStep(dx: 1, dy: 6),
        ])

        #expect(axes == [.vertical, .horizontal, .vertical])
    }

    @Test("A sideways swipe stays sideways through its later moves and momentum")
    func horizontalGestureKeepsItsAxis() {
        let axes = Self.routedAxes([
            WheelStep(phase: .began, dx: 9, dy: 2),
            WheelStep(phase: .changed, dx: 1, dy: 9),
            WheelStep(phase: .ended),
            WheelStep(momentum: .began, dx: 1, dy: 9),
            WheelStep(momentum: .changed, dy: 9),
            WheelStep(momentum: .ended),
        ])

        #expect(axes == Array(repeating: .horizontal, count: 6))
    }

    @Test("A vertical swipe stays vertical through its later moves")
    func verticalGestureKeepsItsAxis() {
        let axes = Self.routedAxes([
            WheelStep(phase: .began, dx: 1, dy: 8),
            WheelStep(phase: .changed, dx: 9, dy: 1),
            WheelStep(momentum: .began, dx: 9),
        ])

        #expect(axes == [.vertical, .vertical, .vertical])
    }

    @Test("Each swipe decides again, and a resting touch leaves the decision to the first move")
    func eachGestureDecidesAgain() {
        let axes = Self.routedAxes([
            WheelStep(phase: .began, dx: 1, dy: 8),
            WheelStep(phase: .ended),
            WheelStep(phase: .mayBegin),
            WheelStep(phase: .began),
            WheelStep(phase: .changed, dx: 7, dy: 1),
            WheelStep(phase: .changed, dy: 7),
        ])

        #expect(axes == [.vertical, .vertical, .vertical, .vertical, .horizontal, .horizontal])
    }

    // MARK: - Page

    @Test("A vertical wheel over a grid that fits its rows scrolls the page, a sideways one the grid")
    func verticalWheelGoesToThePage() throws {
        let paged = PagedGrid(rows: GridFixtureRows.wide(rows: 30, columns: 3))
        defer { paged.close() }

        paged.grid.mainScrollView.scrollWheel(with: try wheel(dy: -10))
        #expect(paged.page.wheelEvents.count == 1)

        paged.grid.mainScrollView.scrollWheel(with: try wheel(dx: -12, dy: 1))
        #expect(paged.page.wheelEvents.count == 1)

        paged.grid.frozenScrollView.scrollWheel(with: try wheel(dy: 10))
        #expect(paged.page.wheelEvents.count == 2)
    }

    @Test("A swipe goes to one owner for its whole length")
    func gestureIsNotSplit() throws {
        let paged = PagedGrid(rows: GridFixtureRows.wide(rows: 30, columns: 3))
        defer { paged.close() }
        let scrollView = paged.grid.mainScrollView

        scrollView.scrollWheel(with: try wheel(dx: -9, dy: 2, phase: .began))
        scrollView.scrollWheel(with: try wheel(dx: -1, dy: 9, phase: .changed))
        scrollView.scrollWheel(with: try wheel(phase: .ended))
        scrollView.scrollWheel(with: try wheel(dx: -1, dy: 9, momentum: .begin))
        #expect(paged.page.wheelEvents.isEmpty)

        scrollView.scrollWheel(with: try wheel(dx: 1, dy: -8, phase: .began))
        scrollView.scrollWheel(with: try wheel(dx: -9, dy: 1, phase: .changed))
        scrollView.scrollWheel(with: try wheel(dx: -9, dy: 1, momentum: .continuous))
        #expect(paged.page.wheelEvents.count == 3)
    }

    @Test("Revealing a row scrolls the page to it and leaves the grid at its first row")
    func revealScrollsThePage() {
        let paged = PagedGrid(rows: GridFixtureRows.wide(rows: 30, columns: 3))
        defer { paged.close() }
        #expect(!paged.showsOnPage(row: 29))

        paged.grid.model.reveal(rowID: .existing(29))

        #expect(paged.showsOnPage(row: 29))
        #expect(paged.gridOffset == 0)
    }

    // AppKit asks the table to keep a header-spanning rect in view while the pane resizes; that moved the page before.
    @Test("A resize's own scrollToVisible on the table leaves the page where it is")
    func appKitScrollToVisibleLeavesThePage() {
        let paged = PagedGrid(rows: GridFixtureRows.wide(rows: 30, columns: 3), gridTop: 80)
        defer { paged.close() }
        let before = paged.page.documentVisibleRect.minY

        _ = paged.grid.main.scrollToVisible(NSRect(x: 0, y: -28, width: 600, height: 292))

        #expect(paged.page.documentVisibleRect.minY == before)
    }

    @Test("A row the arrow keys move to is brought onto the page")
    func arrowKeyScrollsThePage() throws {
        let paged = PagedGrid(rows: GridFixtureRows.wide(rows: 30, columns: 3))
        defer { paged.close() }
        paged.grid.focus()
        paged.grid.model.selectCell(GridCoord(row: 25, displayColumn: 0))
        #expect(!paged.showsOnPage(row: 26))

        let downArrow = try #require(UnicodeScalar(NSDownArrowFunctionKey))
        try #require(paged.grid.press(String(Character(downArrow)), keyCode: KeyCode.downArrow.rawValue))

        #expect(paged.grid.main.selectedRow == 26)
        #expect(paged.showsOnPage(row: 26))
        #expect(paged.gridOffset == 0)
    }

    @Test("A row the grid just took is revealed once the page has grown to it")
    func revealWaitsForTheGridToGrow() async throws {
        let paged = PagedGrid(rows: GridFixtureRows.wide(rows: 30, columns: 3))
        defer { paged.close() }

        paged.grid.model.apply(paged.grid.owner.tableRows.appendInsertedRow(values: Array(repeating: PluginCellValue.text("new"), count: 3)))
        let inserted = try #require(paged.grid.model.rowID(at: 30))
        paged.grid.model.reveal(rowID: inserted)
        #expect(paged.gridOffset == 0)

        paged.fit()

        try await waitUntil { paged.showsOnPage(row: 30) }
        #expect(paged.gridOffset == 0)
    }
}
