//
//  ColumnWindowResolverTests.swift
//  TableProTests
//
//  NSTableView virtualises rows but never columns, so a 500-column result mounts a cell view per
//  column per prepared row and every scroll frame lays all of them out. The window keeps the
//  document's full width through spacers, so scroll extent has to survive every decision here.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column window resolver")
struct ColumnWindowResolverTests {
    private let wide = Array(repeating: CGFloat(100), count: 500)

    private func totalWidth(_ window: ColumnWindowResolver.Window, widths: [CGFloat]) -> CGFloat {
        let mounted = widths[window.range].reduce(0, +)
        return window.leadingWidth + mounted + window.trailingWidth
    }

    @Test("A range that already covers the column needs no widening")
    func containingIsNilWhenAlreadyMounted() {
        #expect(ColumnWindowResolver.window(containing: 20, columnWidths: wide, current: 10..<40) == nil)
    }

    @Test("An out-of-bounds column widens nothing")
    func containingIsNilOutOfBounds() {
        #expect(ColumnWindowResolver.window(containing: 500, columnWidths: wide, current: nil) == nil)
    }

    /// Stretching the mounted range out to reach a far column would mount every column in between,
    /// which is the cost the window exists to avoid. The caller scrolls in the same turn, so the
    /// columns it leaves behind are never drawn again.
    @Test("Reaching a far column mounts a window around it, not everything in between")
    func containingRecentresRatherThanStretches() throws {
        let window = try #require(
            ColumnWindowResolver.window(containing: 400, columnWidths: wide, current: 0..<30)
        )

        #expect(window.range.contains(400))
        #expect(window.range.count <= ColumnWindowResolver.overscan * 2 + 1)
        #expect(totalWidth(window, widths: wide) == wide.reduce(0, +))
    }

    @Test("Reaching a column with no window yet mounts a window around it")
    func containingFromNoWindow() throws {
        let window = try #require(
            ColumnWindowResolver.window(containing: 250, columnWidths: wide, current: nil)
        )

        #expect(window.range.contains(250))
        #expect(window.range.count < 50)
        #expect(totalWidth(window, widths: wide) == wide.reduce(0, +))
    }

    @Test("No columns resolves to an empty window")
    func emptyColumns() {
        let window = ColumnWindowResolver.resolve(
            columnWidths: [], viewportMinX: 0, viewportWidth: 800, current: nil
        )
        #expect(window == .empty)
    }

    @Test("A window mounts far fewer columns than the result has")
    func windowIsSmall() {
        let window = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 0, viewportWidth: 800, current: nil
        )
        #expect(window.range.count < 50)
        #expect(window.range.lowerBound == 0)
    }

    /// The spacers exist so the horizontal scroller still spans the whole result. If this drifts,
    /// the grid silently loses columns the user can no longer reach.
    @Test(
        "Document width is preserved at every scroll position",
        arguments: [CGFloat(0), 1_000, 24_950, 49_200]
    )
    func documentWidthPreserved(minX: CGFloat) {
        let window = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: minX, viewportWidth: 800, current: nil
        )
        #expect(totalWidth(window, widths: wide) == 50_000)
    }

    @Test("Document width is preserved for 0, 1, 50 and 500 columns")
    func documentWidthAcrossColumnCounts() {
        for count in [1, 50, 500] {
            let widths = Array(repeating: CGFloat(100), count: count)
            let window = ColumnWindowResolver.resolve(
                columnWidths: widths, viewportMinX: 0, viewportWidth: 800, current: nil
            )
            #expect(totalWidth(window, widths: widths) == CGFloat(count) * 100)
        }
    }

    @Test("The window covers the columns under the viewport")
    func windowCoversViewport() {
        let window = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 10_000, viewportWidth: 800, current: nil
        )
        #expect(window.range.contains(100))
        #expect(window.range.contains(107))
    }

    @Test("Scrolled to the far end the window stops at the last column")
    func windowClampsAtEnd() {
        let window = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 49_200, viewportWidth: 800, current: nil
        )
        #expect(window.range.upperBound == 500)
        #expect(window.trailingWidth == 0)
    }

    // MARK: - Hysteresis

    /// Re-windowing costs a tile, and doing it per column put that tile inside the scroll frame.
    @Test("A small scroll inside the mounted range does not move the window")
    func smallScrollKeepsWindow() {
        let first = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 10_000, viewportWidth: 800, current: nil
        )
        let second = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 10_100, viewportWidth: 800, current: first.range
        )
        #expect(second.range == first.range)
    }

    @Test("Scrolling past the margin moves the window")
    func largeScrollMovesWindow() {
        let first = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 10_000, viewportWidth: 800, current: nil
        )
        let second = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 20_000, viewportWidth: 800, current: first.range
        )
        #expect(second.range != first.range)
        #expect(second.range.contains(200))
    }

    /// The margin has to be smaller than the overscan, or it can never be satisfied and every
    /// scroll re-windows. That is exactly what the first version of this did.
    @Test("The slide margin leaves room to move inside the mounted window")
    func marginFitsInsideOverscan() {
        #expect(ColumnWindowResolver.slideMargin < ColumnWindowResolver.overscan)
    }

    @Test("A window already at the start does not slide just because there is no leading margin")
    func atStartDoesNotThrash() {
        let first = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 0, viewportWidth: 800, current: nil
        )
        let second = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 0, viewportWidth: 800, current: first.range
        )
        #expect(second.range == first.range)
        #expect(second.leadingWidth == 0)
    }

    @Test("A viewport wider than the result mounts everything")
    func viewportWiderThanResult() {
        let widths = Array(repeating: CGFloat(100), count: 20)
        let window = ColumnWindowResolver.resolve(
            columnWidths: widths, viewportMinX: 0, viewportWidth: 5_000, current: nil
        )
        #expect(window.range == 0..<20)
        #expect(window.leadingWidth == 0)
        #expect(window.trailingWidth == 0)
    }

    @Test("Uneven column widths still preserve the document width")
    func unevenWidths() {
        let widths: [CGFloat] = (0..<200).map { CGFloat(40 + ($0 % 7) * 30) }
        let expected = widths.reduce(0, +)
        let window = ColumnWindowResolver.resolve(
            columnWidths: widths, viewportMinX: 3_000, viewportWidth: 700, current: nil
        )
        #expect(totalWidth(window, widths: widths) == expected)
    }

    @Test("A zero-width viewport still mounts a usable window")
    func zeroWidthViewport() {
        let window = ColumnWindowResolver.resolve(
            columnWidths: wide, viewportMinX: 0, viewportWidth: 0, current: nil
        )
        #expect(!window.range.isEmpty)
        #expect(totalWidth(window, widths: wide) == 50_000)
    }
}
