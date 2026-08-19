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
    func defaultConfiguration() throws {
        let columns = ResultChartColumn.columns(in: makeRows(
            columns: ["name", "amount"],
            types: [.text(rawType: nil), .decimal(rawType: nil)]
        ))
        let resolved = try #require(ResultChartConfiguration().resolved(in: columns))

        #expect(resolved.xColumn == nil)
        #expect(resolved.yColumn.name == "amount")
        #expect(resolved.chartType == .bar)
    }

    @Test("The default Y axis skips the primary key so the first chart is not a row-id diagonal")
    func defaultYSkipsPrimaryKey() throws {
        let columns = ResultChartColumn.columns(
            in: makeRows(
                columns: ["TrackId", "Name", "Milliseconds"],
                types: [.integer(rawType: nil), .text(rawType: nil), .integer(rawType: nil)]
            ),
            primaryKeyColumns: ["TrackId"]
        )
        let resolved = try #require(ResultChartConfiguration().resolved(in: columns))

        #expect(resolved.yColumn.name == "Milliseconds")
    }

    @Test("A result whose only numeric column is the key still charts it")
    func defaultYFallsBackToTheKey() throws {
        let columns = ResultChartColumn.columns(
            in: makeRows(columns: ["TrackId", "Name"], types: [.integer(rawType: nil), .text(rawType: nil)]),
            primaryKeyColumns: ["TrackId"]
        )
        let resolved = try #require(ResultChartConfiguration().resolved(in: columns))

        #expect(resolved.yColumn.name == "TrackId")
    }

    @Test("A tab keeps its chart choices when the result set is replaced")
    func configurationSurvivesResultReplacement() {
        var tab = QueryTab(title: "Query", tabType: .query)
        tab.chartConfiguration.chartType = .scatter
        tab.chartConfiguration.xColumn = ResultChartColumnID(name: "name", occurrence: 1)

        tab.display.replaceUnpinnedResults(with: [ResultSet(label: "Second", tableRows: TableRows())])

        #expect(tab.chartConfiguration.chartType == .scatter)
        #expect(tab.chartConfiguration.xColumn == ResultChartColumnID(name: "name", occurrence: 1))
    }

    @Test("Choices follow the column name, so a reordered SELECT cannot chart a different column")
    func choicesFollowColumnNames() throws {
        let configuration = ResultChartConfiguration(
            xColumn: ResultChartColumnID(name: "name", occurrence: 1),
            yColumn: ResultChartColumnID(name: "amount", occurrence: 1)
        )
        let reordered = ResultChartColumn.columns(in: makeRows(
            columns: ["amount", "name"],
            types: [.decimal(rawType: nil), .text(rawType: nil)]
        ))
        let resolved = try #require(configuration.resolved(in: reordered))

        #expect(resolved.xColumn?.name == "name")
        #expect(resolved.yColumn.name == "amount")
    }

    @Test("A choice whose column is missing falls back without being erased")
    func missingChoiceFallsBackWithoutErasing() throws {
        var configuration = ResultChartConfiguration(
            xColumn: ResultChartColumnID(name: "month", occurrence: 1),
            yColumn: ResultChartColumnID(name: "revenue", occurrence: 1)
        )
        let other = ResultChartColumn.columns(in: makeRows(
            columns: ["name", "amount"],
            types: [.text(rawType: nil), .decimal(rawType: nil)]
        ))
        let resolved = try #require(configuration.resolved(in: other))

        #expect(resolved.xColumn == nil)
        #expect(resolved.yColumn.name == "amount")
        #expect(configuration.yColumn == ResultChartColumnID(name: "revenue", occurrence: 1))

        configuration.chartType = .line
        #expect(configuration.xColumn == ResultChartColumnID(name: "month", occurrence: 1))
    }

    @Test("Changing chart type does not invalidate the data projection")
    func chartTypeDoesNotChangeProjectionKey() throws {
        let tabId = UUID()
        let resultSetId = UUID()
        let columns = ResultChartColumn.columns(in: makeRows(
            columns: ["name", "amount", "channel"],
            types: [.text(rawType: nil), .decimal(rawType: nil), .text(rawType: nil)]
        ))
        var configuration = ResultChartConfiguration(
            chartType: .bar,
            xColumn: columns[0].id,
            yColumn: columns[1].id,
            seriesColumn: columns[2].id
        )
        func key() -> ResultChartProjectionKey {
            ResultChartProjectionKey(
                tabId: tabId,
                resultSetId: resultSetId,
                dataRevision: 7,
                resolved: configuration.resolved(in: columns),
                isUnlocked: true
            )
        }

        let barKey = key()
        configuration.chartType = .line
        let lineKey = key()
        #expect(barKey == lineKey)

        configuration.xColumn = nil
        #expect(key() != lineKey)
    }

    @Test("Duplicate column names have stable occurrence labels and identity")
    func duplicateColumns() {
        let columns = ResultChartColumn.columns(in: makeRows(
            columns: ["value", "value", "group"],
            types: [.integer(rawType: nil), .decimal(rawType: nil), .text(rawType: nil)]
        ))

        #expect(columns.map(\.displayName) == ["value (1)", "value (2)", "group"])
        #expect(columns.map(\.id) == [
            ResultChartColumnID(name: "value", occurrence: 1),
            ResultChartColumnID(name: "value", occurrence: 2),
            ResultChartColumnID(name: "group", occurrence: 1),
        ])
    }

    @Test("A result with no numeric column cannot be charted")
    func noNumericColumn() {
        let columns = ResultChartColumn.columns(in: makeRows(
            columns: ["payload", "name"],
            types: [.json(rawType: nil), .text(rawType: nil)]
        ))

        #expect(ResultChartConfiguration().resolved(in: columns) == nil)
    }

    @Test("Column eligibility follows typed metadata, not the cell spelling")
    func columnEligibility() {
        let columns = ResultChartColumn.columns(in: makeRows(
            columns: ["text", "integer", "decimal", "date", "stamp", "bool", "blob", "json", "spatial", "array"],
            types: [
                .text(rawType: nil),
                .integer(rawType: nil),
                .decimal(rawType: nil),
                .date(rawType: nil),
                .timestamp(rawType: nil),
                .boolean(rawType: nil),
                .blob(rawType: nil),
                .json(rawType: nil),
                .spatial(rawType: nil),
                .array(rawType: nil, element: .integer(rawType: nil)),
            ]
        ))

        #expect(columns.map(\.xAxisKind) == [
            .category, .number, .number, .date, .date, .category, nil, nil, nil, nil,
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
