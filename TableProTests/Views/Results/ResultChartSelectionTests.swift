//
//  ResultChartSelectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Result chart selection")
struct ResultChartSelectionTests {
    @Test("Categorical selection includes every series at the selected X value")
    func categoricalSelectionIncludesEverySeries() throws {
        let projection = projection(points: [
            point(index: 0, x: .category("Jan"), rawX: "Jan", y: 10, series: "Online"),
            point(index: 1, x: .category("Jan"), rawX: "Jan", y: 12, series: "Retail"),
            point(index: 2, x: .category("Feb"), rawX: "Feb", y: 14, series: "Online"),
        ])

        let selection = try #require(ResultChartSelection.categorical(in: projection, selectedX: "Jan"))

        #expect(selection.rawX == "Jan")
        #expect(selection.points.map(\.sourceIndex) == [0, 1])
    }

    @Test("Unknown categorical selection produces no callout")
    func unknownCategoricalSelectionProducesNothing() {
        let projection = projection(points: [
            point(index: 0, x: .category("Jan"), rawX: "Jan", y: 10),
        ])

        #expect(ResultChartSelection.categorical(in: projection, selectedX: "Feb") == nil)
        #expect(ResultChartSelection.categorical(in: projection, selectedX: nil) == nil)
    }

    @Test("Numeric selection resolves the nearest plotted X value")
    func numericSelectionResolvesNearestValue() throws {
        let projection = projection(points: [
            point(index: 0, x: .number(10), rawX: "10", y: 1),
            point(index: 1, x: .number(20), rawX: "20", y: 2),
            point(index: 2, x: .number(20), rawX: "20.0", y: 3),
        ])

        let selection = try #require(ResultChartSelection.numeric(in: projection, selectedX: 18))

        #expect(selection.x == .number(20))
        #expect(selection.rawX == "20")
        #expect(selection.points.map(\.sourceIndex) == [1, 2])
    }

    @Test("Numeric ties resolve by source order")
    func numericTieResolvesBySourceOrder() throws {
        let projection = projection(points: [
            point(index: 4, x: .number(20), rawX: "20", y: 2),
            point(index: 2, x: .number(10), rawX: "10", y: 1),
        ])

        let selection = try #require(ResultChartSelection.numeric(in: projection, selectedX: 15))

        #expect(selection.x == .number(10))
    }

    @Test("Missing and nonfinite numeric selections produce no callout")
    func missingAndNonfiniteNumericSelectionsProduceNothing() {
        let projection = projection(points: [
            point(index: 0, x: .number(10), rawX: "10", y: 1),
        ])

        #expect(ResultChartSelection.numeric(in: projection, selectedX: nil) == nil)
        #expect(ResultChartSelection.numeric(in: projection, selectedX: .nan) == nil)
    }

    private func projection(points: [ResultChartProjection.Point]) -> ResultChartProjection {
        ResultChartProjection(
            points: points,
            issue: nil,
            loadedRowCount: points.count,
            skippedRowCount: 0,
            xAxisLabel: "Month",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel"
        )
    }

    private func point(
        index: Int,
        x: ResultChartProjection.XValue,
        rawX: String,
        y: Int,
        series: String? = nil
    ) -> ResultChartProjection.Point {
        ResultChartProjection.Point(
            sourceIndex: index,
            x: x,
            y: Decimal(y),
            rawX: rawX,
            rawY: String(y),
            series: series.map(ResultChartProjection.SeriesValue.value),
            barGroup: 0,
            lineGroup: 0
        )
    }
}
