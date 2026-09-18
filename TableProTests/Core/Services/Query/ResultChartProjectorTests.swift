//
//  ResultChartProjectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ResultChartProjector")
struct ResultChartProjectorTests {
    @Test("Projects one point per valid row without aggregating duplicate categories")
    func projectsRowsWithoutAggregation() async throws {
        let rows = makeRows(
            values: [
                [.text("A"), .text("10")],
                [.text("A"), .text("20")],
                [.text("B"), .text("30")],
            ],
            columns: ["category", "value"],
            types: [.text(rawType: "TEXT"), .integer(rawType: "BIGINT")]
        )
        let projection = try await project(rows, x: "category", y: "value")

        #expect(projection.limits.isEmpty)
        #expect(projection.points.count == 3)
        #expect(projection.points.map(\.rawX) == ["A", "A", "B"])
        #expect(projection.points.map(\.rawY) == ["10", "20", "30"])
        #expect(projection.points[0].barGroup != projection.points[1].barGroup)
    }

    @Test("Ordinary two-decimal money values plot instead of being dropped as imprecise")
    func moneyValuesPlot() async throws {
        let prices = ["19.99", "0.07", "1.07", "0.11", "0.21", "5.00", "10.50", "3.25", "7.99", "2.50"]
        let rows = makeRows(
            values: prices.enumerated().map { [.text("p\($0.offset)"), .text($0.element)] },
            columns: ["product", "price"],
            types: [.text(rawType: "TEXT"), .decimal(rawType: "DECIMAL(10,2)")]
        )
        let projection = try await project(rows, x: "product", y: "price")

        #expect(projection.points.count == prices.count)
        #expect(projection.skippedRowCount == 0)
        #expect(projection.points.map(\.rawY) == prices)
    }

    @Test("Accepts only values that Swift Charts can plot without precision loss")
    func exactChartPrimitives() async throws {
        let rows = makeRows(
            values: [
                [.text("9007199254740992"), .text("9007199254740992")],
                [.text("9007199254740993"), .text("1")],
                [.text("2"), .text("9007199254740993")],
                [.text("3"), .text("1234567890.125")],
                [.text("4"), .text("1234567890.123456789")],
            ],
            columns: ["x", "y"],
            types: [.decimal(rawType: "DECIMAL"), .decimal(rawType: "DECIMAL")]
        )
        let projection = try await project(rows, x: "x", y: "y")

        #expect(projection.points.map(\.rawX) == ["9007199254740992", "3"])
        #expect(projection.points.map(\.rawY) == ["9007199254740992", "1234567890.125"])
        #expect(projection.skippedRowCount == 3)
    }

    @Test("Numeric-equivalent X spellings receive distinct bar positions")
    func equivalentNumericXValues() async throws {
        let rows = makeRows(
            values: [
                [.text("1"), .text("10")],
                [.text("1.0"), .text("20")],
                [.text("1e0"), .text("30")],
            ],
            columns: ["x", "y"],
            types: [.integer(rawType: nil), .integer(rawType: nil)]
        )
        let projection = try await project(rows, x: "x", y: "y")

        #expect(projection.points.map(\.x) == [.number(1), .number(1), .number(1)])
        #expect(Set(projection.points.map(\.barGroup)).count == 3)
    }

    @Test("A date column plots on a temporal axis in chronological order")
    func dateAxisIsTemporal() async throws {
        let rows = makeRows(
            values: [
                [.text("2024-9-1"), .text("10")],
                [.text("2024-10-1"), .text("20")],
                [.text("2024-03-01 08:30:00+07"), .text("30")],
            ],
            columns: ["when", "value"],
            types: [.timestamp(rawType: "TIMESTAMPTZ"), .integer(rawType: nil)]
        )
        let projection = try await project(rows, x: "when", y: "value")

        #expect(projection.xAxisKind == .date)
        #expect(projection.points.count == 3)
        let dates: [Date] = projection.points.compactMap {
            guard case .date(let value) = $0.x else { return nil }
            return value
        }
        try #require(dates.count == 3)
        #expect(dates[2] < dates[0])
        #expect(dates[0] < dates[1])
        #expect(projection.points.map(\.rawX) == ["2024-9-1", "2024-10-1", "2024-03-01 08:30:00+07"])
    }

    @Test("An unparseable date is skipped rather than charted as a label")
    func unparseableDateIsSkipped() async throws {
        let rows = makeRows(
            values: [
                [.text("2024-03-01"), .text("10")],
                [.text("not a date"), .text("20")],
            ],
            columns: ["when", "value"],
            types: [.date(rawType: "DATE"), .integer(rawType: nil)]
        )
        let projection = try await project(rows, x: "when", y: "value")

        #expect(projection.points.map(\.rawX) == ["2024-03-01"])
        #expect(projection.skippedRowCount == 1)
    }

    @Test("Bar series keep stable positions when row order changes between categories")
    func stableBarSeriesPositions() async throws {
        let rows = makeRows(
            values: [
                [.text("A"), .text("10"), .text("first")],
                [.text("A"), .text("20"), .text("second")],
                [.text("B"), .text("30"), .text("second")],
                [.text("B"), .text("40"), .text("first")],
            ],
            columns: ["x", "y", "series"],
            types: [.text(rawType: nil), .integer(rawType: nil), .text(rawType: nil)]
        )
        let projection = try await project(rows, x: "x", y: "y", series: "series")

        #expect(projection.points[0].barGroup == projection.points[3].barGroup)
        #expect(projection.points[1].barGroup == projection.points[2].barGroup)
        #expect(projection.points[0].barGroup != projection.points[1].barGroup)
    }

    @Test("An invalid row breaks only its own line series")
    func invalidRowBreaksItsOwnSeries() async throws {
        let otherSeriesInvalid = makeRows(
            values: [
                [.text("1"), .text("10"), .text("A")],
                [.text("2"), .null, .text("B")],
                [.text("3"), .text("30"), .text("A")],
            ],
            columns: ["x", "y", "series"],
            types: [.integer(rawType: nil), .integer(rawType: nil), .text(rawType: nil)]
        )
        let ownSeriesInvalid = makeRows(
            values: [
                [.text("1"), .text("10"), .text("A")],
                [.text("2"), .null, .text("A")],
                [.text("3"), .text("30"), .text("A")],
            ],
            columns: ["x", "y", "series"],
            types: [.integer(rawType: nil), .integer(rawType: nil), .text(rawType: nil)]
        )

        let unaffected = try await project(otherSeriesInvalid, x: "x", y: "y", series: "series")
        let broken = try await project(ownSeriesInvalid, x: "x", y: "y", series: "series")

        #expect(unaffected.points.count == 2)
        #expect(unaffected.points[0].lineGroup == unaffected.points[1].lineGroup)
        #expect(broken.points.count == 2)
        #expect(broken.points[0].lineGroup != broken.points[1].lineGroup)
    }

    @Test("A row whose series cannot be read breaks every line, because it cannot be attributed")
    func unreadableSeriesBreaksEveryLine() async throws {
        let rows = makeRows(
            values: [
                [.text("1"), .text("10"), .text("A")],
                [.text("2"), .text("20"), .text("B")],
                [.text("3"), .text("30"), .bytes(Data([0x01]))],
                [.text("4"), .text("40"), .text("A")],
                [.text("5"), .text("50"), .text("B")],
            ],
            columns: ["x", "y", "series"],
            types: [.integer(rawType: nil), .integer(rawType: nil), .text(rawType: nil)]
        )
        let projection = try await project(rows, x: "x", y: "y", series: "series")

        #expect(projection.points.count == 4)
        #expect(projection.skippedRowCount == 1)
        #expect(projection.points[0].lineGroup != projection.points[2].lineGroup)
        #expect(projection.points[1].lineGroup != projection.points[3].lineGroup)
    }

    @Test("Skips null, binary, invalid, and unrepresentable axis values")
    func skipsInvalidAxisValues() async throws {
        let rows = makeRows(
            values: [
                [.text("A"), .text("1")],
                [.null, .text("2")],
                [.text("C"), .null],
                [.text("D"), .bytes(Data([0x01]))],
                [.text("E"), .text("NaN")],
                [.text("F"), .text("1e1000")],
                [.text("G"), .text("115792089237316195423570985008687907853269984665640564039457584007913129639935")],
                [.text("H"), .text("1e3")],
            ],
            columns: ["category", "value"],
            types: [.text(rawType: nil), .decimal(rawType: nil)]
        )
        let projection = try await project(rows, x: "category", y: "value")

        #expect(projection.points.map(\.rawX) == ["A", "H"])
        #expect(projection.skippedRowCount == 6)
        #expect(projection.points[0].lineGroup != projection.points[1].lineGroup)
    }

    @Test("Row number is a one-based numeric X axis")
    func rowNumberXAxis() async throws {
        let rows = makeRows(
            values: [[.text("4")], [.text("8")]],
            columns: ["value"],
            types: [.integer(rawType: nil)]
        )
        let projection = try await project(rows, y: "value")

        #expect(projection.points.map(\.rawX) == ["1", "2"])
        #expect(projection.xAxisKind == .number)
        #expect(projection.xAxisLabel == String(localized: "Row Number"))
    }

    @Test("Null series values share one stable bucket")
    func nullSeriesBucket() async throws {
        let rows = makeRows(
            values: [
                [.text("1"), .null],
                [.text("2"), .null],
                [.text("3"), .text("paid")],
            ],
            columns: ["value", "status"],
            types: [.integer(rawType: nil), .text(rawType: nil)]
        )
        let projection = try await project(rows, y: "value", series: "status")

        #expect(projection.points.map(\.series) == [.missing, .missing, .value("paid")])
    }

    @Test("Passing the point cap truncates and says so instead of discarding the chart")
    func pointLimitTruncates() async throws {
        let accepted = try await project(
            makeNumericRows(count: ResultChartProjector.maximumPointCount),
            y: "value"
        )
        let truncated = try await project(
            makeNumericRows(count: ResultChartProjector.maximumPointCount + 1),
            y: "value"
        )

        #expect(accepted.points.count == ResultChartProjector.maximumPointCount)
        #expect(accepted.limits.isEmpty)
        #expect(truncated.points.count == ResultChartProjector.maximumPointCount)
        #expect(truncated.limits == [.points(limit: ResultChartProjector.maximumPointCount)])
    }

    @Test("Passing the series cap keeps the series already plotted")
    func seriesLimitKeepsPlottedSeries() async throws {
        let accepted = try await project(
            makeSeriesRows(count: ResultChartProjector.maximumSeriesCount),
            y: "value",
            series: "series"
        )
        let truncated = try await project(
            makeSeriesRows(count: ResultChartProjector.maximumSeriesCount + 3),
            y: "value",
            series: "series"
        )

        #expect(accepted.limits.isEmpty)
        #expect(truncated.points.count == ResultChartProjector.maximumSeriesCount)
        #expect(truncated.limits == [.series(limit: ResultChartProjector.maximumSeriesCount)])
        #expect(Set(truncated.points.compactMap(\.series)).count == ResultChartProjector.maximumSeriesCount)
    }

    @Test("Passing the inspection cap charts the prefix it did inspect")
    func inspectionLimitChartsThePrefix() async throws {
        let rows = makeNumericRows(count: ResultChartProjector.maximumInspectedRowCount + 1)
        let projection = try await project(rows, y: "value")

        #expect(projection.limits.contains(.points(limit: ResultChartProjector.maximumPointCount)))
        #expect(projection.points.count == ResultChartProjector.maximumPointCount)
    }

    @Test("Inspection stops after fifty thousand unusable rows")
    func inspectionLimitBoundsUnusableRows() async throws {
        let rows = makeRows(
            values: Array(
                repeating: [PluginCellValue.null],
                count: ResultChartProjector.maximumInspectedRowCount + 1
            ),
            columns: ["value"],
            types: [.integer(rawType: nil)]
        )
        let projection = try await project(rows, y: "value")

        #expect(projection.limits == [.inspectedRows(limit: ResultChartProjector.maximumInspectedRowCount)])
        #expect(projection.skippedRowCount == ResultChartProjector.maximumInspectedRowCount)
        #expect(projection.points.isEmpty)
    }

    @Test("Skips oversized values before building chart labels and group identities")
    func oversizedValues() async throws {
        let longLabel = String(repeating: "x", count: ResultChartProjector.maximumLabelLength + 1)
        let longNumber = String(repeating: "9", count: ResultChartProjector.maximumNumericLength + 1)
        let rows = makeRows(
            values: [
                [.text("A"), .text("1"), .text("ok")],
                [.text(longLabel), .text("2"), .text("ok")],
                [.text("C"), .text(longNumber), .text("ok")],
                [.text("D"), .text("4"), .text(longLabel)],
            ],
            columns: ["category", "value", "series"],
            types: [.text(rawType: nil), .decimal(rawType: nil), .text(rawType: nil)]
        )
        let projection = try await project(rows, x: "category", y: "value", series: "series")

        #expect(projection.points.map(\.rawX) == ["A"])
        #expect(projection.skippedRowCount == 3)
        #expect(projection.points[0].barGroup == 0)
        #expect(projection.points[0].lineGroup == 0)
    }

    @Test("A cancelled projection stops before publishing points")
    func cancellation() async throws {
        let rows = makeNumericRows(count: 10_000)
        let configuration = try resolve(rows, y: "value")
        let task = Task {
            try await ResultChartProjector.shared.project(tableRows: rows, configuration: configuration)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func resolve(
        _ rows: TableRows,
        x: String? = nil,
        y: String,
        series: String? = nil
    ) throws -> ResultChartConfiguration.Resolved {
        let configuration = ResultChartConfiguration(
            xColumn: x.map { ResultChartColumnID(name: $0, occurrence: 1) },
            yColumn: ResultChartColumnID(name: y, occurrence: 1),
            seriesColumn: series.map { ResultChartColumnID(name: $0, occurrence: 1) }
        )
        return try #require(configuration.resolved(in: ResultChartColumn.columns(in: rows)))
    }

    private func project(
        _ rows: TableRows,
        x: String? = nil,
        y: String,
        series: String? = nil
    ) async throws -> ResultChartProjection {
        let configuration = try resolve(rows, x: x, y: y, series: series)
        return try await ResultChartProjector.shared.project(tableRows: rows, configuration: configuration)
    }

    private func makeNumericRows(count: Int) -> TableRows {
        makeRows(
            values: (0..<count).map { [.text(String($0))] },
            columns: ["value"],
            types: [.integer(rawType: "BIGINT")]
        )
    }

    private func makeSeriesRows(count: Int) -> TableRows {
        makeRows(
            values: (0..<count).map { [.text(String($0)), .text("series-\($0)")] },
            columns: ["value", "series"],
            types: [.integer(rawType: nil), .text(rawType: nil)]
        )
    }

    private func makeRows(
        values: [[PluginCellValue]],
        columns: [String],
        types: [ColumnType]
    ) -> TableRows {
        TableRows.from(queryRows: values, columns: columns, columnTypes: types)
    }
}
