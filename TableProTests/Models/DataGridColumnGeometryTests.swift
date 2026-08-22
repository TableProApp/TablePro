//
//  DataGridColumnGeometryTests.swift
//  TableProTests
//
//  The grid draws its cells instead of mounting one view per cell, so this is the only thing that
//  knows where a column is. Every click, every overlay, every accessibility element and every draw
//  pass resolves through it, so its geometry is worth more tests than the code that calls it.
//

import CoreGraphics
import Testing

@testable import TablePro

@Suite("Data grid column geometry")
struct DataGridColumnGeometryTests {
    private func uniform(_ count: Int, width: CGFloat = 100, spacing: CGFloat = 1) -> DataGridColumnGeometry {
        DataGridColumnGeometry(
            dataIndices: Array(0..<count),
            widths: Array(repeating: width, count: count),
            spacing: spacing
        )
    }

    @Test("No columns is an empty geometry")
    func emptyGeometry() {
        let geometry = DataGridColumnGeometry.empty

        #expect(geometry.isEmpty)
        #expect(geometry.count == 0)
        #expect(geometry.totalWidth == 0)
        #expect(geometry.displayPosition(atX: 0) == nil)
        #expect(geometry.displayPositions(intersecting: 0...100).isEmpty)
    }

    @Test("Columns are laid out end to end, each followed by one gap")
    func columnsAreLaidOutInOrder() throws {
        let geometry = uniform(4, width: 100, spacing: 1)

        #expect(try #require(geometry.column(atDisplayPosition: 0)).x == 0)
        #expect(try #require(geometry.column(atDisplayPosition: 1)).x == 101)
        #expect(try #require(geometry.column(atDisplayPosition: 2)).x == 202)
        #expect(try #require(geometry.column(atDisplayPosition: 3)).x == 303)
        #expect(geometry.totalWidth == 404)
    }

    @Test("A column of a different width shifts everything after it")
    func widthsAccumulate() throws {
        let geometry = DataGridColumnGeometry(
            dataIndices: [0, 1, 2],
            widths: [50, 200, 75],
            spacing: 1
        )

        #expect(try #require(geometry.column(atDisplayPosition: 1)).x == 51)
        #expect(try #require(geometry.column(atDisplayPosition: 2)).x == 252)
        #expect(geometry.totalWidth == 328)
    }

    // MARK: - Hitting a column

    @Test("A point inside a column finds it")
    func pointInsideAColumn() {
        let geometry = uniform(10)

        #expect(geometry.displayPosition(atX: 0) == 0)
        #expect(geometry.displayPosition(atX: 99) == 0)
        #expect(geometry.displayPosition(atX: 101) == 1)
        #expect(geometry.displayPosition(atX: 505) == 5)
    }

    /// A click must always land on a cell. Without this the reader can press the gap between two
    /// columns and have nothing happen.
    @Test("A point in the gap after a column belongs to that column")
    func pointInTheGap() {
        let geometry = uniform(10, width: 100, spacing: 4)

        #expect(geometry.displayPosition(atX: 100) == 0)
        #expect(geometry.displayPosition(atX: 103) == 0)
        #expect(geometry.displayPosition(atX: 104) == 1)
    }

    @Test("A point outside the run finds no column")
    func pointOutsideTheRun() {
        let geometry = uniform(5)

        #expect(geometry.displayPosition(atX: -1) == nil)
        #expect(geometry.displayPosition(atX: geometry.totalWidth) == nil)
        #expect(geometry.displayPosition(atX: geometry.totalWidth + 500) == nil)
    }

    @Test("Every column is found at its own leading edge")
    func everyColumnIsReachable() {
        let geometry = DataGridColumnGeometry(
            dataIndices: Array(0..<500),
            widths: (0..<500).map { CGFloat(110 + ($0 * 37) % 90) },
            spacing: 1
        )

        for position in 0..<geometry.count {
            let column = geometry.column(atDisplayPosition: position)
            #expect(geometry.displayPosition(atX: column?.x ?? -1) == position)
        }
    }

    // MARK: - Drawing a viewport

    @Test("A span covers every column it touches and no others")
    func spanCoversTouchedColumns() {
        let geometry = uniform(100, width: 100, spacing: 1)

        let visible = geometry.displayPositions(intersecting: 250...550)

        #expect(visible.contains(2))
        #expect(visible.contains(5))
        #expect(!visible.contains(7))
    }

    @Test("A span past either end yields nothing rather than a bad index")
    func spanOutsideTheRun() {
        let geometry = uniform(10)

        #expect(geometry.displayPositions(intersecting: -500 ... -10).isEmpty)
        #expect(geometry.displayPositions(intersecting: 5000...6000).isEmpty)
    }

    /// What a draw pass costs is the whole point of drawing rather than mounting: the work has to
    /// follow the viewport, not the result.
    @Test("A viewport covers the same few columns whatever the result's width")
    func viewportCostDoesNotFollowColumnCount() {
        for count in [100, 500, 5000] {
            let geometry = uniform(count, width: 120, spacing: 1)
            let visible = geometry.displayPositions(intersecting: 6000...7200)

            #expect(visible.count <= 12)
            #expect(!visible.isEmpty)
        }
    }

    // MARK: - Rects

    @Test("A cell's rect sits at its column's offset inside the row")
    func cellRectInsideRow() throws {
        let geometry = uniform(5, width: 100, spacing: 1)
        let row = CGRect(x: 0, y: 44, width: geometry.totalWidth, height: 22)

        let rect = try #require(geometry.rect(atDisplayPosition: 2, inRow: row))

        #expect(rect.minX == 202)
        #expect(rect.width == 100)
        #expect(rect.minY == 44)
        #expect(rect.height == 22)
    }

    @Test("A row drawn at an offset carries its cells with it")
    func cellRectFollowsTheRowOrigin() throws {
        let geometry = uniform(5, width: 100, spacing: 1)
        let row = CGRect(x: 40, y: 0, width: geometry.totalWidth, height: 22)

        let rect = try #require(geometry.rect(atDisplayPosition: 1, inRow: row))

        #expect(rect.minX == 141)
    }

    @Test("An out-of-range position has no rect")
    func rectOutOfRange() {
        let geometry = uniform(3)
        let row = CGRect(x: 0, y: 0, width: 300, height: 22)

        #expect(geometry.rect(atDisplayPosition: 3, inRow: row) == nil)
        #expect(geometry.rect(atDisplayPosition: -1, inRow: row) == nil)
    }

    // MARK: - Data index mapping

    /// Display position and data index are only equal until the reader drags a column, and every
    /// consumer needs both, so one lookup has to answer for the other.
    @Test("A reordered run maps display position and data index both ways")
    func dataIndexMapping() throws {
        let geometry = DataGridColumnGeometry(
            dataIndices: [3, 0, 2, 1],
            widths: [100, 100, 100, 100],
            spacing: 1
        )

        #expect(geometry.displayPosition(ofDataIndex: 3) == 0)
        #expect(geometry.displayPosition(ofDataIndex: 1) == 3)
        #expect(try #require(geometry.column(atDisplayPosition: 0)).dataIndex == 3)
        #expect(try #require(geometry.column(withDataIndex: 1)).x == 303)
    }

    @Test("A data index the result does not present has no position")
    func unknownDataIndex() {
        let geometry = uniform(3)

        #expect(geometry.displayPosition(ofDataIndex: 99) == nil)
        #expect(geometry.column(withDataIndex: 99) == nil)
    }

    // MARK: - Gestures

    @Test("Resizing a column moves the ones after it and no others")
    func resizingAColumn() throws {
        let resized = uniform(4, width: 100, spacing: 1).settingWidth(250, atDisplayPosition: 1)

        #expect(try #require(resized.column(atDisplayPosition: 0)).x == 0)
        #expect(try #require(resized.column(atDisplayPosition: 1)).width == 250)
        #expect(try #require(resized.column(atDisplayPosition: 2)).x == 352)
        #expect(resized.totalWidth == 554)
    }

    @Test("Reordering a column carries its width with it")
    func reorderingCarriesWidth() throws {
        let geometry = DataGridColumnGeometry(
            dataIndices: [0, 1, 2],
            widths: [50, 200, 75],
            spacing: 1
        )

        let moved = geometry.movingColumn(atDisplayPosition: 1, to: 0)

        #expect(try #require(moved.column(atDisplayPosition: 0)).dataIndex == 1)
        #expect(try #require(moved.column(atDisplayPosition: 0)).width == 200)
        #expect(moved.displayPosition(ofDataIndex: 1) == 0)
        #expect(moved.totalWidth == geometry.totalWidth)
    }

    @Test("A gesture that changes nothing returns the same geometry")
    func inertGestures() {
        let geometry = uniform(4)

        #expect(geometry.movingColumn(atDisplayPosition: 1, to: 1) == geometry)
        #expect(geometry.movingColumn(atDisplayPosition: 9, to: 0) == geometry)
        #expect(geometry.settingWidth(50, atDisplayPosition: 9) == geometry)
    }
}
