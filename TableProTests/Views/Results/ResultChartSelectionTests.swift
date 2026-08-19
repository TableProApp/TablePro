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
        let index = ResultChartSelectionIndex(projection: projection(points: [
            point(index: 0, x: .category("Jan"), rawX: "Jan", y: 10, series: "Online"),
            point(index: 1, x: .category("Jan"), rawX: "Jan", y: 12, series: "Retail"),
            point(index: 2, x: .category("Feb"), rawX: "Feb", y: 14, series: "Online"),
        ]))

        let selection = try #require(index.selection(forCategory: "Jan"))

        #expect(selection.rawX == "Jan")
        #expect(selection.points.map(\.sourceIndex) == [0, 1])
    }

    @Test("Unknown categorical selection produces no callout")
    func unknownCategoricalSelectionProducesNothing() {
        let index = ResultChartSelectionIndex(projection: projection(points: [
            point(index: 0, x: .category("Jan"), rawX: "Jan", y: 10),
        ]))

        #expect(index.selection(forCategory: "Feb") == nil)
        #expect(index.selection(forCategory: nil) == nil)
    }

    @Test("Numeric selection resolves the nearest plotted X value")
    func numericSelectionResolvesNearestValue() throws {
        let index = ResultChartSelectionIndex(projection: projection(points: [
            point(index: 0, x: .number(10), rawX: "10", y: 1),
            point(index: 1, x: .number(20), rawX: "20", y: 2),
            point(index: 2, x: .number(20), rawX: "20.0", y: 3),
        ]))

        let selection = try #require(index.selection(nearestNumber: 18))

        #expect(selection.x == .number(20))
        #expect(selection.rawX == "20")
        #expect(selection.points.map(\.sourceIndex) == [1, 2])
    }

    @Test("A pointer exactly between two values resolves to the lower one")
    func numericTieResolvesToTheLowerValue() throws {
        let index = ResultChartSelectionIndex(projection: projection(points: [
            point(index: 4, x: .number(20), rawX: "20", y: 2),
            point(index: 2, x: .number(10), rawX: "10", y: 1),
        ]))

        let selection = try #require(index.selection(nearestNumber: 15))

        #expect(selection.x == .number(10))
    }

    @Test("A pointer beyond the plotted range clamps to the end value")
    func numericSelectionClampsToRange() throws {
        let index = ResultChartSelectionIndex(projection: projection(points: [
            point(index: 0, x: .number(10), rawX: "10", y: 1),
            point(index: 1, x: .number(20), rawX: "20", y: 2),
        ]))

        #expect(try #require(index.selection(nearestNumber: -500)).x == .number(10))
        #expect(try #require(index.selection(nearestNumber: 500)).x == .number(20))
    }

    @Test("Missing and nonfinite numeric selections produce no callout")
    func missingAndNonfiniteNumericSelectionsProduceNothing() {
        let index = ResultChartSelectionIndex(projection: projection(points: [
            point(index: 0, x: .number(10), rawX: "10", y: 1),
        ]))

        #expect(index.selection(nearestNumber: nil) == nil)
        #expect(index.selection(nearestNumber: .nan) == nil)
    }

    @Test("Date selection resolves the nearest plotted instant")
    func dateSelectionResolvesNearestInstant() throws {
        let january = Date(timeIntervalSince1970: 1_704_067_200)
        let march = Date(timeIntervalSince1970: 1_709_251_200)
        let index = ResultChartSelectionIndex(projection: projection(points: [
            point(index: 0, x: .date(january), rawX: "2024-01-01", y: 1),
            point(index: 1, x: .date(march), rawX: "2024-03-01", y: 2),
        ]))

        let selection = try #require(index.selection(nearestDate: march.addingTimeInterval(-3_600)))

        #expect(selection.x == .date(march))
        #expect(index.selection(nearestDate: nil) == nil)
    }

    private func projection(points: [ResultChartProjection.Point]) -> ResultChartProjection {
        ResultChartProjection(
            points: points,
            xAxisKind: .category,
            limits: [],
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
            y: Double(y),
            rawX: rawX,
            rawY: String(y),
            series: series.map(ResultChartProjection.SeriesValue.value),
            barGroup: 0,
            lineGroup: 0
        )
    }
}
