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
    @Test("Result scope distinguishes query truncation from table pagination")
    func resultScope() {
        var queryPagination = PaginationState(pageSize: 1_000)
        queryPagination.hasMoreRows = true
        #expect(ResultChartDataScope.hasUnloadedRows(
            tabType: .query,
            pagination: queryPagination,
            loadedRowCount: 1_000
        ))

        queryPagination.hasMoreRows = false
        #expect(!ResultChartDataScope.hasUnloadedRows(
            tabType: .query,
            pagination: queryPagination,
            loadedRowCount: 10_000
        ))

        var tablePagination = PaginationState(totalRowCount: 1_500, pageSize: 1_000)
        #expect(ResultChartDataScope.hasUnloadedRows(
            tabType: .table,
            pagination: tablePagination,
            loadedRowCount: 1_000
        ))

        tablePagination.currentPage = 2
        #expect(!ResultChartDataScope.hasUnloadedRows(
            tabType: .table,
            pagination: tablePagination,
            loadedRowCount: 500
        ))
    }

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
        let configuration = try #require(
            ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 1)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

        #expect(projection.issue == nil)
        #expect(projection.points.count == 3)
        #expect(projection.points.map(\.rawX) == ["A", "A", "B"])
        #expect(projection.points.map(\.rawY) == ["10", "20", "30"])
        #expect(projection.points[0].barGroup != projection.points[1].barGroup)
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
        let configuration = try #require(
            ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 1)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

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
        let configuration = try #require(
            ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 1)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

        #expect(projection.points.map(\.x) == [.number(1), .number(1), .number(1)])
        #expect(Set(projection.points.map(\.barGroup)).count == 3)
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
        let configuration = try #require(
            ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 1, seriesColumnIndex: 2)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

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
        let configuration = try #require(
            ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 1, seriesColumnIndex: 2)
                .resolved(in: ResultChartColumn.columns(in: otherSeriesInvalid))
        )

        let unaffected = try await ResultChartProjector.shared.project(
            tableRows: otherSeriesInvalid,
            configuration: configuration
        )
        let broken = try await ResultChartProjector.shared.project(
            tableRows: ownSeriesInvalid,
            configuration: configuration
        )

        #expect(unaffected.points.count == 2)
        #expect(unaffected.points[0].lineGroup == unaffected.points[1].lineGroup)
        #expect(broken.points.count == 2)
        #expect(broken.points[0].lineGroup != broken.points[1].lineGroup)
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
        let configuration = try #require(
            ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 1)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

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
        let configuration = try #require(
            ResultChartConfiguration(yColumnIndex: 0)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

        #expect(projection.points.map(\.rawX) == ["1", "2"])
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
        let configuration = try #require(
            ResultChartConfiguration(yColumnIndex: 0, seriesColumnIndex: 1)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

        #expect(projection.points.map(\.series) == [.missing, .missing, .value("paid")])
    }

    @Test("Accepts two thousand points and refuses the next point without sampling")
    func pointLimit() async throws {
        let acceptedRows = makeNumericRows(count: ResultChartProjector.maximumPointCount)
        let configuration = try #require(
            ResultChartConfiguration(yColumnIndex: 0)
                .resolved(in: ResultChartColumn.columns(in: acceptedRows))
        )

        let accepted = try await ResultChartProjector.shared.project(
            tableRows: acceptedRows,
            configuration: configuration
        )
        let refused = try await ResultChartProjector.shared.project(
            tableRows: makeNumericRows(count: ResultChartProjector.maximumPointCount + 1),
            configuration: configuration
        )

        #expect(accepted.points.count == ResultChartProjector.maximumPointCount)
        #expect(accepted.issue == nil)
        #expect(refused.points.isEmpty)
        #expect(refused.issue == .tooManyPoints(limit: ResultChartProjector.maximumPointCount))
    }

    @Test("Accepts twenty series and refuses the twenty-first")
    func seriesLimit() async throws {
        let acceptedRows = makeSeriesRows(count: ResultChartProjector.maximumSeriesCount)
        let configuration = try #require(
            ResultChartConfiguration(yColumnIndex: 0, seriesColumnIndex: 1)
                .resolved(in: ResultChartColumn.columns(in: acceptedRows))
        )

        let accepted = try await ResultChartProjector.shared.project(
            tableRows: acceptedRows,
            configuration: configuration
        )
        let refused = try await ResultChartProjector.shared.project(
            tableRows: makeSeriesRows(count: ResultChartProjector.maximumSeriesCount + 1),
            configuration: configuration
        )

        #expect(accepted.issue == nil)
        #expect(refused.points.isEmpty)
        #expect(refused.issue == .tooManySeries(limit: ResultChartProjector.maximumSeriesCount))
    }

    @Test("Bounds invalid-row inspection before another chart waits on the shared projector")
    func inspectionLimit() async throws {
        let rows = makeRows(
            values: Array(
                repeating: [PluginCellValue.null],
                count: ResultChartProjector.maximumInspectedRowCount + 1
            ),
            columns: ["value"],
            types: [.integer(rawType: nil)]
        )
        let configuration = try #require(
            ResultChartConfiguration(yColumnIndex: 0)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

        #expect(projection.issue == .tooManyRows(limit: ResultChartProjector.maximumInspectedRowCount))
        #expect(projection.skippedRowCount == ResultChartProjector.maximumInspectedRowCount)
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
        let configuration = try #require(
            ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 1, seriesColumnIndex: 2)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )

        let projection = try await ResultChartProjector.shared.project(
            tableRows: rows,
            configuration: configuration
        )

        #expect(projection.points.map(\.rawX) == ["A"])
        #expect(projection.skippedRowCount == 3)
        #expect(projection.points[0].barGroup == 0)
        #expect(projection.points[0].lineGroup == 0)
    }

    @Test("A cancelled projection stops before publishing points")
    func cancellation() async throws {
        let rows = makeNumericRows(count: 10_000)
        let configuration = try #require(
            ResultChartConfiguration(yColumnIndex: 0)
                .resolved(in: ResultChartColumn.columns(in: rows))
        )
        let task = Task {
            try await ResultChartProjector.shared.project(tableRows: rows, configuration: configuration)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
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
