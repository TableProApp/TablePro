import Foundation
@testable import TablePro
import Testing

@Suite("GridDragClamp")
struct GridDragClampTests {
    private let firstPresented = 1
    private let lastPresented = 4
    private let lastMaxX: CGFloat = 500

    @Test("a drag past the trailing edge holds the last column")
    func pastTrailingEdgeHoldsLastColumn() {
        let resolved = GridDragClamp.column(
            hit: -1,
            pointX: 5_000,
            firstPresented: firstPresented,
            lastPresented: lastPresented,
            lastPresentedMaxX: lastMaxX
        )

        #expect(resolved == lastPresented)
    }

    @Test("a drag past the leading edge holds the first column")
    func pastLeadingEdgeHoldsFirstColumn() {
        let resolved = GridDragClamp.column(
            hit: -1,
            pointX: -30,
            firstPresented: firstPresented,
            lastPresented: lastPresented,
            lastPresentedMaxX: lastMaxX
        )

        #expect(resolved == firstPresented)
    }

    @Test("a hit inside the run is clamped into the presented range")
    func hitInsideRunIsClamped() {
        #expect(clampColumn(hit: 3, x: 200) == 3)
        #expect(clampColumn(hit: 0, x: 10) == firstPresented)
        #expect(clampColumn(hit: 9, x: 480) == lastPresented)
    }

    @Test("a grid presenting no column resolves nothing")
    func noPresentedColumnResolvesNothing() {
        #expect(GridDragClamp.column(
            hit: -1, pointX: 100, firstPresented: -1, lastPresented: -1, lastPresentedMaxX: 0
        ) == nil)
    }

    @Test("a drag below the last row holds the last row")
    func belowLastRowHoldsLastRow() {
        #expect(GridDragClamp.row(hit: -1, pointY: 99_999, rowCount: 40, lastRowMaxY: 880) == 39)
    }

    @Test("a drag above the first row holds the first row")
    func aboveFirstRowHoldsFirstRow() {
        #expect(GridDragClamp.row(hit: -1, pointY: -30, rowCount: 40, lastRowMaxY: 880) == 0)
    }

    @Test("a row hit past the end is clamped to the last row")
    func rowHitPastEndIsClamped() {
        #expect(GridDragClamp.row(hit: 99, pointY: 400, rowCount: 40, lastRowMaxY: 880) == 39)
        #expect(GridDragClamp.row(hit: 7, pointY: 160, rowCount: 40, lastRowMaxY: 880) == 7)
    }

    @Test("an empty grid resolves no row")
    func emptyGridResolvesNoRow() {
        #expect(GridDragClamp.row(hit: -1, pointY: 10, rowCount: 0, lastRowMaxY: 0) == nil)
    }

    private func clampColumn(hit: Int, x: CGFloat) -> Int? {
        GridDragClamp.column(
            hit: hit,
            pointX: x,
            firstPresented: firstPresented,
            lastPresented: lastPresented,
            lastPresentedMaxX: lastMaxX
        )
    }
}
