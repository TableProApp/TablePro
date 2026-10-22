//
//  UnloadedValuePlanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct UnloadedValuePlanTests {
    private static let types: [String: ColumnType] = [
        "id": .integer(rawType: "INT"),
        "name": .text(rawType: "VARCHAR"),
        "data": .blob(rawType: "LONGBLOB"),
        "thumb": .blob(rawType: "MEDIUMBLOB")
    ]
    private static let columns = ["id", "name", "data", "thumb"]

    private static func plan(
        primaryKeys: [String] = ["id"],
        sortColumns: [String] = [],
        valueFilteredColumns: [String] = [],
        function: String? = "OCTET_LENGTH",
        limit: Int = 65_536
    ) -> UnloadedValuePlan? {
        UnloadedValuePlan.resolve(
            selectedColumns: columns,
            columnTypes: types,
            primaryKeys: primaryKeys,
            sortColumns: sortColumns,
            valueFilteredColumns: valueFilteredColumns,
            byteLengthFunction: function,
            inlineByteLimit: limit
        )
    }

    private static var mysqlBuilder: TableQueryBuilder {
        TableQueryBuilder(
            databaseType: .mysql,
            dialect: SQLDialectDescriptor(
                identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
                regexSyntax: .regexp, booleanLiteralStyle: .numeric,
                likeEscapeStyle: .implicit, paginationStyle: .limit
            ),
            pagination: .offset,
            dialectQuote: { "`\($0)`" }
        )
    }

    @Test("Binary columns are deferred, the key and other columns are not")
    func defersBinaryColumns() {
        #expect(Self.plan()?.columns == ["data", "thumb"])
    }

    @Test("A table without a primary key keeps every value in the page")
    func noPrimaryKeyNoPlan() {
        #expect(Self.plan(primaryKeys: []) == nil)
    }

    @Test("An engine without a byte length function keeps every value in the page")
    func noFunctionNoPlan() {
        #expect(Self.plan(function: nil) == nil)
    }

    @Test("Sorted and value-filtered columns keep their values")
    func sortedAndFilteredColumnsStay() {
        #expect(Self.plan(sortColumns: ["data"])?.columns == ["thumb"])
        #expect(Self.plan(sortColumns: ["data"], valueFilteredColumns: ["thumb"]) == nil)
    }

    @Test("The page reads a deferred column only up to the limit, with its length at the end")
    func baseQueryProjection() throws {
        let plan = try #require(Self.plan(limit: 1_024))
        let query = Self.mysqlBuilder.buildBaseQuery(
            tableName: "files", columns: Self.columns, selectColumns: Self.columns,
            unloadedValues: plan, limit: 200, offset: 0
        )
        #expect(query == """
            SELECT `id`, `name`, CASE WHEN OCTET_LENGTH(`data`) <= 1024 THEN `data` END AS `data`, \
            CASE WHEN OCTET_LENGTH(`thumb`) <= 1024 THEN `thumb` END AS `thumb`, \
            OCTET_LENGTH(`data`) AS `__tablepro_byte_length_2`, \
            OCTET_LENGTH(`thumb`) AS `__tablepro_byte_length_3` FROM `files` LIMIT 200 OFFSET 0
            """)
    }

    @Test("A filtered page defers the same way")
    func filteredQueryProjection() throws {
        let plan = try #require(Self.plan())
        var filter = TableFilter()
        filter.columnName = "name"
        filter.filterOperator = .equal
        filter.value = "a"
        filter.isEnabled = true
        let query = try #require(Self.mysqlBuilder.buildFilteredQuery(
            tableName: "files", filters: [filter], columns: Self.columns,
            selectColumns: Self.columns, unloadedValues: plan
        ))
        #expect(query.hasPrefix("SELECT `id`, `name`, CASE WHEN OCTET_LENGTH(`data`) <= 65536 THEN `data` END AS `data`"))
        #expect(query.contains("WHERE"))
    }

    @Test("Folding strips the length columns and marks only withheld values")
    func foldMarksWithheldValues() throws {
        let rows: [[PluginCellValue]] = [
            ["1", "a", .null, .bytes(Data([1])), "5242880", "1"],
            ["2", "b", .bytes(Data([2, 3])), .null, "2", .null],
            ["3", "c", .null, .null, .null, .null]
        ]
        let fold = try #require(UnloadedValueFold.fold(
            columns: ["id", "name", "data", "thumb", "__tablepro_byte_length_2", "__tablepro_byte_length_3"],
            columnTypes: [
                .integer(rawType: "INT"), .text(rawType: "VARCHAR"), .blob(rawType: "LONGBLOB"),
                .blob(rawType: "LONGBLOB"), .integer(rawType: "BIGINT"), .integer(rawType: "BIGINT")
            ],
            rows: rows,
            columnMeta: nil,
            lengthColumns: ["__tablepro_byte_length_2", "__tablepro_byte_length_3"]
        ))
        #expect(fold.columns == ["id", "name", "data", "thumb"])
        #expect(fold.columnTypes.count == 4)
        #expect(fold.rows.allSatisfy { $0.count == 4 })
        #expect(fold.unloadedCells == [0: [2: 5_242_880]])
        #expect(fold.rows[1][2] == .bytes(Data([2, 3])))
    }

    @Test("A result without the planned length columns is left alone")
    func foldIgnoresOtherResults() {
        #expect(UnloadedValueFold.fold(
            columns: ["id", "name"], columnTypes: [], rows: [["1", "a"]], columnMeta: nil,
            lengthColumns: ["__tablepro_byte_length_1"]
        ) == nil)
        #expect(UnloadedValueFold.fold(
            columns: ["id", "__tablepro_byte_length_0"], columnTypes: [], rows: [[.null, "1"]], columnMeta: nil,
            lengthColumns: []
        ) == nil)
    }

    @Test("The length aliases follow the deferred columns' places in the select list")
    func lengthColumnsMatchSelectList() throws {
        let plan = try #require(Self.plan())
        #expect(plan.lengthColumns(for: Self.columns) == ["__tablepro_byte_length_2", "__tablepro_byte_length_3"])
    }

    @Test("A folded page builds rows that know which values are on the server")
    func foldedPageBuildsUnloadedRows() {
        let result = QueryFetchResult(
            columns: ["id", "data", "__tablepro_byte_length_1"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "LONGBLOB"), .integer(rawType: "BIGINT")],
            rows: [["1", .null, "70000"]],
            executionTime: 0,
            rowsAffected: 0,
            statusMessage: nil,
            isTruncated: false,
            resultColumnMeta: nil
        ).foldingUnloadedValues(lengthColumns: ["__tablepro_byte_length_1"])
        let tableRows = TableRows.from(
            queryRows: result.rows, columns: result.columns, columnTypes: result.columnTypes,
            unloadedCells: result.unloadedCells
        )
        #expect(tableRows.columns == ["id", "data"])
        #expect(tableRows.unloadedByteCount(row: 0, column: 1) == 70_000)
        #expect(tableRows.hasUnloadedValues)
    }
}

struct TableRowsUnloadedValueTests {
    private static func rows() -> TableRows {
        TableRows.from(
            queryRows: [["1", "a", .null], ["2", "b", .null]],
            columns: ["id", "name", "data"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR"), .blob(rawType: "LONGBLOB")],
            unloadedCells: [0: [2: 10], 1: [2: 20]]
        )
    }

    @Test("Filling writes the value and clears the mark, by row identity")
    func fillWritesValue() {
        var tableRows = Self.rows()
        let delta = tableRows.fillUnloaded([.existing(1): [2: .bytes(Data([9]))]])
        #expect(delta == .cellsChanged([CellPosition(row: 1, column: 2)]))
        #expect(tableRows.value(at: 1, column: 2) == .bytes(Data([9])))
        #expect(tableRows.unloadedByteCount(row: 1, column: 2) == nil)
        #expect(tableRows.unloadedByteCount(row: 0, column: 2) == 10)
    }

    @Test("A cell already loaded keeps its value when a late fill arrives")
    func fillSkipsLoadedCells() {
        var tableRows = Self.rows()
        tableRows.fillUnloaded([.existing(0): [2: .bytes(Data([1]))]])
        let delta = tableRows.fillUnloaded([.existing(0): [2: .bytes(Data([2]))]])
        #expect(delta == .none)
        #expect(tableRows.value(at: 0, column: 2) == .bytes(Data([1])))
    }

    @Test("Writing NULL into an unloaded cell is a change, and the cell is loaded after")
    func editClearsMark() {
        var tableRows = Self.rows()
        let delta = tableRows.edit(row: 0, column: 2, value: .null)
        #expect(delta == .cellChanged(row: 0, column: 2))
        #expect(tableRows.unloadedByteCount(row: 0, column: 2) == nil)
    }

    @Test("A replaced page carries its own marks")
    func replaceCarriesMarks() {
        var tableRows = Self.rows()
        tableRows.replace(rows: [["3", "c", .null]], unloadedCells: [0: [2: 30]])
        #expect(tableRows.unloadedByteCount(row: 0, column: 2) == 30)
        #expect(tableRows.count == 1)
    }

    @Test("The grid shows an unloaded cell's size in place of NULL")
    func placeholderShowsSize() {
        let placeholder = DataGridCellContent.placeholder(for: .null, unloadedByteCount: 5_242_880)
        #expect(placeholder == .unloaded(byteCount: 5_242_880))
        let text = DataGridCellContent.resolvedDisplayText(
            "", placeholder: placeholder, isLargeDataset: false, nullDisplayString: "NULL"
        )
        #expect(text == ByteCountFormatter.string(fromByteCount: 5_242_880, countStyle: .file))
    }
}
