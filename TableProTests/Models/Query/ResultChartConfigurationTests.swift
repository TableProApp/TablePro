//
//  ResultChartConfigurationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("ResultChartConfiguration")
struct ResultChartConfigurationTests {
    @Test("A result defaults to row number and its first typed numeric column")
    func defaultConfiguration() {
        let rows = makeRows(
            columns: ["name", "amount"],
            types: [.text(rawType: nil), .decimal(rawType: nil)]
        )
        let result = ResultSet(label: "Result", tableRows: rows)

        #expect(result.chartConfiguration.xColumnIndex == nil)
        #expect(result.chartConfiguration.yColumnIndex == 1)
        #expect(result.chartConfiguration.chartType == .bar)
    }

    @Test("Configuration stays independent across pinned results")
    func independentPerResult() {
        let rows = makeRows(
            columns: ["name", "amount"],
            types: [.text(rawType: nil), .decimal(rawType: nil)]
        )
        let first = ResultSet(label: "First", tableRows: rows)
        let second = ResultSet(label: "Second", tableRows: rows)

        first.chartConfiguration.chartType = .scatter
        first.chartConfiguration.xColumnIndex = 0
        first.chartConfiguration.seriesColumnIndex = 0

        #expect(second.chartConfiguration.chartType == .bar)
        #expect(second.chartConfiguration.xColumnIndex == nil)
        #expect(second.chartConfiguration.seriesColumnIndex == nil)
    }

    @Test("Changing chart type does not invalidate the data projection")
    func chartTypeDoesNotChangeProjectionKey() {
        let tabId = UUID()
        let resultSetId = UUID()
        var configuration = ResultChartConfiguration(
            chartType: .bar,
            xColumnIndex: 0,
            yColumnIndex: 1,
            seriesColumnIndex: 2
        )
        let barKey = ResultChartProjectionKey(
            tabId: tabId,
            resultSetId: resultSetId,
            dataRevision: 7,
            configuration: configuration,
            isUnlocked: true
        )

        configuration.chartType = .line
        let lineKey = ResultChartProjectionKey(
            tabId: tabId,
            resultSetId: resultSetId,
            dataRevision: 7,
            configuration: configuration,
            isUnlocked: true
        )

        #expect(barKey == lineKey)

        configuration.yColumnIndex = 3
        let changedAxisKey = ResultChartProjectionKey(
            tabId: tabId,
            resultSetId: resultSetId,
            dataRevision: 7,
            configuration: configuration,
            isUnlocked: true
        )
        #expect(changedAxisKey != lineKey)
    }

    @Test("Duplicate column names have stable occurrence labels and index identity")
    func duplicateColumns() {
        let rows = makeRows(
            columns: ["value", "value", "group"],
            types: [.integer(rawType: nil), .decimal(rawType: nil), .text(rawType: nil)]
        )
        let columns = ResultChartColumn.columns(in: rows)

        #expect(columns.map(\.displayName) == ["value (1)", "value (2)", "group"])
        #expect(columns.map(\.id) == [0, 1, 2])
    }

    @Test("Unsupported or stale selections do not silently remap")
    func invalidSelection() {
        let rows = makeRows(
            columns: ["payload", "name"],
            types: [.json(rawType: nil), .text(rawType: nil)]
        )
        let columns = ResultChartColumn.columns(in: rows)

        #expect(ResultChartConfiguration(xColumnIndex: 0, yColumnIndex: 4).resolved(in: columns) == nil)
        #expect(ResultChartConfiguration(xColumnIndex: 1, yColumnIndex: 1).resolved(in: columns) == nil)
    }

    @Test("Column eligibility follows typed metadata, not the cell spelling")
    func columnEligibility() {
        let rows = makeRows(
            columns: ["text", "integer", "decimal", "date", "bool", "blob", "json", "spatial", "array"],
            types: [
                .text(rawType: nil),
                .integer(rawType: nil),
                .decimal(rawType: nil),
                .date(rawType: nil),
                .boolean(rawType: nil),
                .blob(rawType: nil),
                .json(rawType: nil),
                .spatial(rawType: nil),
                .array(rawType: nil, element: .integer(rawType: nil)),
            ]
        )
        let columns = ResultChartColumn.columns(in: rows)

        #expect(columns.map(\.xAxisKind) == [
            .category, .number, .number, .category, .category, nil, nil, nil, nil,
        ])
        #expect(columns.filter(\.supportsY).map(\.name) == ["integer", "decimal"])
        #expect(columns.filter(\.supportsSeries).map(\.name) == ["text", "bool"])
    }

    private func makeRows(columns: [String], types: [ColumnType]) -> TableRows {
        TableRows.from(
            queryRows: [Array(repeating: PluginCellValue.text("42"), count: columns.count)],
            columns: columns,
            columnTypes: types
        )
    }
}
