//
//  EditorTabRunLayoutTests.swift
//  TableProTests
//

import CoreGraphics
import Foundation
import Testing

@testable import TablePro

@Suite("Editor tab run layout")
struct EditorTabRunLayoutTests {
    private static let trackWidth: CGFloat = 604

    @Test("Tabs that fit share the track in one row")
    func fittingTabsShareOneRow() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 3, overflow: .scroll)

        #expect(run.rowCount == 1)
        #expect(run.placements.count == 3)
        #expect(run.tabWidth == 200)
        #expect(run.placements.map(\.frame.minX) == [0, 200, 400])
        #expect(run.placements.allSatisfy { $0.row == 0 })
    }

    @Test("Scrolling keeps one row and lets the content run past the track")
    func scrollingKeepsOneRow() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 12, overflow: .scroll)

        #expect(run.rowCount == 1)
        #expect(run.tabWidth == EditorTabStripLayout.minimumTabWidth)
        #expect(run.contentSize.width == EditorTabStripLayout.minimumTabWidth * 12)
        #expect(run.contentSize.width > Self.trackWidth)
    }

    /// The whole point of the wrapped run: nothing is off screen, so a tab opened first is still
    /// reachable however many followed it.
    @Test("Wrapping never runs wider than the track")
    func wrappingNeverOverflows() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 12, overflow: .rows)

        #expect(run.tabsPerRow == 5)
        #expect(run.rowCount == 3)
        #expect(run.contentSize.width <= Self.trackWidth)
        #expect(run.placements.map(\.row) == [0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2])
    }

    @Test("A wrapped run stacks its rows by the row stride")
    func wrappedRowsStack() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 7, overflow: .rows)
        let second = run.placement(at: 5)

        #expect(second?.row == 1)
        #expect(second?.frame.minY == EditorTabStripLayout.rowStride)
        #expect(second?.frame.minX == 0)
    }

    /// A narrow window still shows one tab per row rather than dividing by zero.
    @Test("A track narrower than one tab keeps a single column")
    func narrowTrackKeepsOneColumn() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: 40, count: 4, overflow: .rows)

        #expect(run.tabsPerRow == 1)
        #expect(run.rowCount == 4)
    }

    @Test("An empty run is empty rather than a single zero-width tab")
    func emptyRun() {
        #expect(EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 0, overflow: .scroll) == .empty)
        #expect(EditorTabRunLayoutBuilder.run(forTrack: 0, count: 4, overflow: .scroll) == .empty)
    }

    @Test("A point inside a tab resolves to it, and the gap after a wrapped last row to nothing")
    func hitTesting() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 6, overflow: .rows)

        #expect(EditorTabRunLayoutBuilder.index(at: CGPoint(x: 10, y: 10), in: run) == 0)
        #expect(EditorTabRunLayoutBuilder.index(at: CGPoint(x: 130, y: 10), in: run) == 1)
        #expect(
            EditorTabRunLayoutBuilder.index(
                at: CGPoint(x: 400, y: EditorTabStripLayout.rowStride + 10),
                in: run
            ) == nil
        )
    }

    @Test("The close button sits in the tab's leading accessory slot")
    func closeButtonRect() throws {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 3, overflow: .scroll)
        let placement = try #require(run.placement(at: 1))
        let rect = EditorTabRunLayoutBuilder.closeButtonRect(in: placement.frame)

        #expect(rect.minX == 200 + EditorTabStripLayout.accessoryInset)
        #expect(rect.width == EditorTabStripLayout.accessoryWidth)
        #expect(rect.midY == EditorTabStripLayout.tabHeight / 2)
    }

    /// One row is already the axis the reorder resolves along, so it is passed through untouched.
    @Test("A single row projects onto its own x")
    func singleRowLinearLocation() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 3, overflow: .scroll)

        #expect(EditorTabRunLayoutBuilder.linearLocation(of: CGPoint(x: 250, y: 5), in: run) == 250)
    }

    /// A wrapped run is projected onto the run it would have been unwrapped, so the reorder keeps
    /// one rule with its midpoint hysteresis rather than growing a second one for rows.
    @Test("A wrapped row contributes a whole row of tabs to the location")
    func wrappedLinearLocation() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 12, overflow: .rows)
        let secondRow = CGPoint(x: 30, y: EditorTabStripLayout.rowStride + 5)

        #expect(
            EditorTabRunLayoutBuilder.linearLocation(of: secondRow, in: run)
                == run.tabWidth * CGFloat(run.tabsPerRow) + 30
        )
    }

    /// A drag that leaves the strip above or below still resolves against the nearest row rather
    /// than jumping to the start of the run.
    @Test("A point above or below the run clamps to the first and last rows")
    func clampedRows() {
        let run = EditorTabRunLayoutBuilder.run(forTrack: Self.trackWidth, count: 12, overflow: .rows)
        let rowWidth = run.tabWidth * CGFloat(run.tabsPerRow)

        #expect(EditorTabRunLayoutBuilder.linearLocation(of: CGPoint(x: 10, y: -200), in: run) == 10)
        #expect(
            EditorTabRunLayoutBuilder.linearLocation(of: CGPoint(x: 10, y: 5_000), in: run)
                == rowWidth * 2 + 10
        )
    }
}
