//
//  DataGridPrewarmWindowTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Data grid prewarm window")
struct DataGridPrewarmWindowTests {
    @Test("The window is bounded by the margin, not by the number of loaded rows")
    func windowDoesNotGrowWithRowCount() {
        let small = DataGridPrewarmWindow.rows(around: 0..<25, displayCount: 1_000)
        let large = DataGridPrewarmWindow.rows(around: 0..<25, displayCount: 250_000)
        #expect(small.count == large.count)
        #expect(large.count <= 25 + 2 * DataGridPrewarmWindow.margin)
    }

    @Test("The window follows the viewport instead of starting at the first row")
    func windowFollowsTheViewport() {
        let window = DataGridPrewarmWindow.rows(around: 5_000..<5_025, displayCount: 20_000)
        #expect(window.contains(5_000))
        #expect(window.contains(5_024))
        #expect(!window.contains(0))
    }

    @Test("The window is clamped to the loaded rows at both ends")
    func windowIsClampedToLoadedRows() {
        let atTop = DataGridPrewarmWindow.rows(around: 0..<10, displayCount: 40)
        #expect(atTop == 0..<40)

        let atBottom = DataGridPrewarmWindow.rows(around: 990..<1_000, displayCount: 1_000)
        #expect(atBottom.upperBound == 1_000)
        #expect(atBottom.lowerBound == 740)
    }

    @Test("An empty result has nothing to prewarm")
    func emptyResultHasNoWindow() {
        #expect(DataGridPrewarmWindow.rows(around: 0..<0, displayCount: 0).isEmpty)
    }

    @Test("A grid with no viewport yet prewarms from the first row")
    func unmeasuredViewportStartsAtTheTop() {
        let window = DataGridPrewarmWindow.rows(around: 0..<0, displayCount: 10_000)
        #expect(window.lowerBound == 0)
        #expect(window.upperBound == DataGridPrewarmWindow.margin)
    }
}
