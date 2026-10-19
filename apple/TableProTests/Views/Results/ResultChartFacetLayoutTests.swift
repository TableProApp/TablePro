//
//  ResultChartFacetLayoutTests.swift
//  TableProTests
//

import CoreGraphics
@testable import TablePro
import Testing

struct ResultChartFacetLayoutTests {
    @Test("Two panels in a wide pane sit side by side at full height")
    func fewPanelsFillThePane() {
        let layout = ResultChartFacetLayout(panelCount: 2, size: CGSize(width: 1_200, height: 600))

        #expect(layout.columns == 2)
        #expect(layout.panelHeight == 600)
    }

    @Test("Past what fits at the minimum size the grid scrolls instead of shrinking")
    func manyPanelsKeepTheMinimumHeight() {
        let layout = ResultChartFacetLayout(panelCount: 12, size: CGSize(width: 1_200, height: 600))

        #expect(layout.columns == 4)
        #expect(layout.panelHeight == ResultChartFacetLayout.minimumPanelHeight)
    }

    @Test("Rows are balanced rather than leaving one panel alone on the last row")
    func rowsAreBalanced() {
        let layout = ResultChartFacetLayout(panelCount: 4, size: CGSize(width: 1_000, height: 600))

        #expect(layout.columns == 2)
        #expect(layout.panelHeight == 294)
    }

    @Test("A narrow pane stacks the panels in one column")
    func narrowPaneStacks() {
        let layout = ResultChartFacetLayout(panelCount: 3, size: CGSize(width: 300, height: 900))

        #expect(layout.columns == 1)
        #expect(layout.panelHeight == 292)
    }
}
