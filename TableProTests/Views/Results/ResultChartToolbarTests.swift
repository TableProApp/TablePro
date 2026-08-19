//
//  ResultChartToolbarTests.swift
//  TableProTests
//

import SwiftUI
@testable import TablePro
import Testing

@MainActor
@Suite("Result chart toolbar")
struct ResultChartToolbarTests {
    @Test("Controls stack when the result pane is narrow")
    func controlsStackAtNarrowWidth() throws {
        let wideHeight = try renderedHeight(width: 1_000)
        let narrowHeight = try renderedHeight(width: 400)

        #expect(wideHeight > 0)
        #expect(narrowHeight > wideHeight + 40)
        #expect(narrowHeight < 220)
    }

    private func renderedHeight(width: CGFloat) throws -> Int {
        let toolbar = ResultChartToolbar(
            configuration: .constant(ResultChartConfiguration(
                chartType: .bar,
                xColumnIndex: 0,
                yColumnIndex: 1,
                seriesColumnIndex: 2
            )),
            columns: [
                ResultChartColumn(
                    index: 0,
                    name: "category",
                    displayName: "A long category column name",
                    type: .text(rawType: nil)
                ),
                ResultChartColumn(
                    index: 1,
                    name: "amount",
                    displayName: "A long numeric column name",
                    type: .decimal(rawType: nil)
                ),
                ResultChartColumn(
                    index: 2,
                    name: "series",
                    displayName: "A long series column name",
                    type: .text(rawType: nil)
                ),
            ],
            loadedRowCount: 40,
            skippedRowCount: 2,
            hasUnloadedRows: true
        )
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: toolbar)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)

        return try #require(renderer.cgImage).height
    }
}
