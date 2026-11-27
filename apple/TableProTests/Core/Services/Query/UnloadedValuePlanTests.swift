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
        "name": .text(rawType: "VARCHAR(255)"),
        "data": .blob(rawType: "LONGBLOB"),
        "thumb": .blob(rawType: "MEDIUMBLOB")
    ]
    private static let columns = ["id", "name", "data", "thumb"]

    private static func plan(
        columns: [String] = columns,
        types: [String: ColumnType] = types,
        primaryKeys: [String] = ["id"],
        sortColumns: [String] = [],
        valueFilteredColumns: [String] = [],
        functions: LargeValueFunctions? = .mySQL,
        limit: Int = 65_536
    ) -> UnloadedValuePlan? {
        UnloadedValuePlan.resolve(
            selectedColumns: columns,
            columnTypes: types,
            primaryKeys: primaryKeys,
            sortColumns: sortColumns,
            valueFilteredColumns: valueFilteredColumns,
            functions: functions,
            inlineByteLimit: limit
        )
    }

    private static func builder(_ type: DatabaseType, quote: Character) -> TableQueryBuilder {
        TableQueryBuilder(
            databaseType: type,
            dialect: SQLDialectDescriptor(
                identifierQuote: String(quote), keywords: [], functions: [], dataTypes: [],
                regexSyntax: .regexp, booleanLiteralStyle: .numeric,
                likeEscapeStyle: .implicit, paginationStyle: .limit
            ),
            pagination: .offset,
            dialectQuote: { "\(quote)\($0)\(quote)" }
        )
    }

    private static var mysqlBuilder: TableQueryBuilder { builder(.mysql, quote: "`") }

    private static let documentTypes: [String: ColumnType] = [
        "id": .integer(rawType: "integer"),
        "body": .text(rawType: "text"),
        "doc": .json(rawType: "jsonb"),
        "code": .text(rawType: "character varying(20)"),
        "note": .text(rawType: "character varying"),
        "uuid": .blob(rawType: "BINARY(16)"),
        "made": .timestamp(rawType: "timestamp")
    ]
    private static let documentColumns = ["id", "body", "doc", "code", "note", "uuid", "made"]

    @Test("Binary columns are deferred, the key and other columns are not")
    func defersBinaryColumns() {
        #expect(Self.plan()?.columns == ["data", "thumb"])
    }

    @Test("Text and JSON that can outgrow the limit are deferred with a head; a declared size under it is not")
    func defersLargeTextAndJSON() throws {
        let plan = try #require(Self.plan(columns: Self.documentColumns, types: Self.documentTypes, functions: .postgreSQL))
        #expect(plan.columns == ["body", "doc", "note"])
        #expect(plan.kinds == ["body": .text, "doc": .document, "note": .text])
    }

    @Test("A declared size counts four bytes a character against the limit")
    func declaredTextSizeAgainstLimit() {
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "varchar(255)"), inlineByteLimit: 1_024) == nil)
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "varchar(300)"), inlineByteLimit: 1_024) == .text)
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "NVARCHAR(MAX)"), inlineByteLimit: 1_024) == .text)
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "uuid"), inlineByteLimit: 1_024) == nil)
        #expect(UnloadedValuePlan.kind(of: .blob(rawType: "VARBINARY(4096)"), inlineByteLimit: 1_024) == .binary)
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "xml"), inlineByteLimit: 1_024) == .document)
    }

    @Test("A MySQL TEXT or BLOB, at most 64 KB, is never cut under the default limit")
    func mySQLBoundedTypes() {
        let bounds = LargeValueFunctions.mySQL.boundedTypeBytes
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "TINYTEXT"), inlineByteLimit: 1_024, boundedTypeBytes: bounds) == nil)
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "TEXT"), inlineByteLimit: 65_536, boundedTypeBytes: bounds) == nil)
        #expect(UnloadedValuePlan.kind(of: .blob(rawType: "BLOB"), inlineByteLimit: 65_536, boundedTypeBytes: bounds) == nil)
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "TEXT"), inlineByteLimit: 1_024, boundedTypeBytes: bounds) == .text)
        #expect(UnloadedValuePlan.kind(of: .text(rawType: "text"), inlineByteLimit: 65_536) == .text)
    }

    @Test("SQLite does not enforce a declared size, so a varchar(255) column is still deferred there")
    func sqliteIgnoresDeclaredSize() throws {
        let types: [String: ColumnType] = ["id": .integer(rawType: "INTEGER"), "title": .text(rawType: "VARCHAR(255)")]
        #expect(Self.plan(columns: ["id", "title"], types: types, functions: .mySQL, limit: 1_024) == nil)
        let plan = try #require(Self.plan(columns: ["id", "title"], types: types, functions: .sqlite, limit: 1_024))
        #expect(plan.kinds == ["title": .text])
    }

    @Test("A table without a primary key keeps every value in the page")
    func noPrimaryKeyNoPlan() {
        #expect(Self.plan(primaryKeys: []) == nil)
    }

    @Test("An engine without large value functions keeps every value in the page")
    func noFunctionsNoPlan() {
        #expect(Self.plan(functions: nil) == nil)
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

    @Test("MySQL reads a long text's first characters after the lengths")
    func mysqlTextProjection() throws {
        let types: [String: ColumnType] = ["id": .integer(rawType: "INT"), "body": .text(rawType: "LONGTEXT")]
        let plan = try #require(Self.plan(columns: ["id", "body"], types: types, limit: 1_024))
        let query = Self.mysqlBuilder.buildBaseQuery(
            tableName: "posts", columns: ["id", "body"], selectColumns: ["id", "body"],
            unloadedValues: plan, limit: 200, offset: 0
        )
        #expect(query == """
            SELECT `id`, CASE WHEN OCTET_LENGTH(`body`) <= 1024 THEN `body` END AS `body`, \
            OCTET_LENGTH(`body`) AS `__tablepro_byte_length_1`, \
            CASE WHEN OCTET_LENGTH(`body`) > 1024 THEN LEFT(`body`, 256) END AS `__tablepro_head_1` \
            FROM `posts` LIMIT 200 OFFSET 0
            """)
    }

    @Test("PostgreSQL settles a jsonb cut by its stored size before measuring its text; bytea is measured as stored")
    func postgreSQLProjection() throws {
        let types: [String: ColumnType] = [
            "id": .integer(rawType: "integer"), "doc": .json(rawType: "jsonb"), "raw": .blob(rawType: "bytea")
        ]
        let plan = try #require(Self.plan(columns: ["id", "doc", "raw"], types: types, functions: .postgreSQL, limit: 1_024))
        let cut = #"(CASE WHEN pg_column_size("doc") > 1024 THEN TRUE WHEN pg_column_size("doc") <= 128 THEN FALSE "#
            + #"ELSE octet_length("doc"::text) > 1024 END)"#
        #expect(plan.selectList(for: ["id", "doc", "raw"], quote: { "\"\($0)\"" }) == """
            "id", CASE WHEN \(cut) THEN NULL ELSE "doc" END AS "doc", \
            CASE WHEN octet_length("raw") <= 1024 THEN "raw" END AS "raw", \
            CASE WHEN \(cut) THEN octet_length("doc"::text) END AS "__tablepro_byte_length_1", \
            octet_length("raw") AS "__tablepro_byte_length_2", \
            CASE WHEN \(cut) THEN substr("doc"::text, 1, 256) END AS "__tablepro_head_1"
            """)
        #expect(plan.layout(for: ["id", "doc", "raw"]).trailingColumns == [
            "__tablepro_byte_length_1", "__tablepro_byte_length_2", "__tablepro_head_1"
        ])
    }

    @Test("PostgreSQL measures a text by its length, which it reads without loading the value")
    func postgreSQLTextProjection() throws {
        let types: [String: ColumnType] = ["id": .integer(rawType: "integer"), "body": .text(rawType: "text")]
        let plan = try #require(Self.plan(columns: ["id", "body"], types: types, functions: .postgreSQL, limit: 1_024))
        #expect(plan.selectList(for: ["id", "body"], quote: { "\"\($0)\"" }) == """
            "id", CASE WHEN octet_length("body"::text) <= 1024 THEN "body" END AS "body", \
            octet_length("body"::text) AS "__tablepro_byte_length_1", \
            CASE WHEN octet_length("body"::text) > 1024 THEN substr("body"::text, 1, 256) END AS "__tablepro_head_1"
            """)
    }

    @Test("SQLite counts a text's bytes through a cast, and keeps a row whose key is NULL whole")
    func sqliteProjection() throws {
        let types: [String: ColumnType] = ["id": .integer(rawType: "INTEGER"), "body": .text(rawType: "TEXT")]
        let plan = try #require(Self.plan(columns: ["id", "body"], types: types, functions: .sqlite, limit: 1_024))
        let cut = #"("id" IS NOT NULL AND length(CAST("body" AS BLOB)) > 1024)"#
        #expect(plan.selectList(for: ["id", "body"], quote: { "\"\($0)\"" }) == """
            "id", CASE WHEN \(cut) THEN NULL ELSE "body" END AS "body", \
            length(CAST("body" AS BLOB)) AS "__tablepro_byte_length_1", \
            CASE WHEN \(cut) THEN substr("body", 1, 256) END AS "__tablepro_head_1"
            """)
    }

    @Test("Every column of a composite SQLite key must hold a value before a cell is cut")
    func sqliteCompositeKeyGuard() throws {
        let types: [String: ColumnType] = [
            "a": .text(rawType: "TEXT"), "b": .text(rawType: "TEXT"), "body": .blob(rawType: "BLOB")
        ]
        let plan = try #require(Self.plan(
            columns: ["a", "b", "body"], types: types, primaryKeys: ["a", "b"], functions: .sqlite, limit: 1_024
        ))
        #expect(plan.nullableKeys == ["a", "b"])
        #expect(plan.selectList(for: ["a", "b", "body"], quote: { "\"\($0)\"" }).contains(
            #"CASE WHEN ("a" IS NOT NULL AND "b" IS NOT NULL AND length(CAST("body" AS BLOB)) > 1024) THEN NULL ELSE "body" END"#
        ))
    }

    @Test("A SQLite key whose column gives it no exact type keeps every value in the page", arguments: [
        "BLOB", "", "NUMERIC", "REAL", "DECIMAL(10,2)"
    ])
    func sqliteLooseKeyNoPlan(keyType: String) {
        let types: [String: ColumnType] = ["id": .blob(rawType: keyType), "body": .text(rawType: "TEXT")]
        #expect(Self.plan(columns: ["id", "body"], types: types, functions: .sqlite, limit: 1_024) == nil)
        #expect(Self.plan(columns: ["id", "body"], types: types, functions: .postgreSQL, limit: 1_024) != nil)
    }

    @Test("A SQLite key typed INTEGER, BIGINT, TEXT or VARCHAR defers the table's large values", arguments: [
        "INTEGER", "BIGINT", "TEXT", "VARCHAR(36)"
    ])
    func sqliteExactKeyDefers(keyType: String) {
        let types: [String: ColumnType] = ["id": .text(rawType: keyType), "body": .text(rawType: "TEXT")]
        #expect(Self.plan(columns: ["id", "body"], types: types, functions: .sqlite, limit: 1_024) != nil)
    }

    @Test("A page stops deferring before its size and head columns pass the engines' column limit")
    func wideTableStaysUnderTheColumnLimit() throws {
        let names = (0..<700).map { "c\($0)" }
        var types: [String: ColumnType] = ["id": .integer(rawType: "INTEGER")]
        for name in names { types[name] = .text(rawType: "TEXT") }
        let selected = ["id"] + names
        let plan = try #require(Self.plan(columns: selected, types: types, functions: .postgreSQL))
        let trailing = plan.layout(for: selected).trailingColumns.count
        #expect(selected.count + trailing <= UnloadedValuePlan.maxResultColumns)
        #expect(plan.columns == Array(names.prefix(449)))
    }

    @Test("An engine whose keys are never NULL cuts on size alone")
    func enforcedKeysNeedNoGuard() throws {
        let types: [String: ColumnType] = ["id": .integer(rawType: "integer"), "body": .text(rawType: "text")]
        for functions in [LargeValueFunctions.postgreSQL, .mySQL] {
            let plan = try #require(Self.plan(columns: ["id", "body"], types: types, functions: functions, limit: 1_024))
            #expect(plan.nullableKeys.isEmpty)
        }
    }

    @Test("A placeholder in a quoted name is not filled in")
    func renderKeepsQuotedName() {
        #expect(LargeValueFunctions.render("LEFT({}, {count})", column: "`a{count}{}`", count: 5) == "LEFT(`a{count}{}`, 5)")
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

    private static let binaryLayout = UnloadedValueLayout(deferred: [
        .init(position: 2, type: .blob(rawType: "LONGBLOB"), readsHead: false),
        .init(position: 3, type: .blob(rawType: "LONGBLOB"), readsHead: false)
    ])

    @Test("Folding strips the length columns and marks only withheld values")
    func foldMarksWithheldValues() throws {
        var rows: [[PluginCellValue]] = [
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
            rows: &rows,
            columnMeta: nil,
            layout: Self.binaryLayout
        ))
        #expect(fold.columns == ["id", "name", "data", "thumb"])
        #expect(fold.columnTypes.count == 4)
        #expect(rows.allSatisfy { $0.count == 4 })
        #expect(fold.unloadedCells == [0: [2: 5_242_880]])
        #expect(rows[1][2] == .bytes(Data([2, 3])))
    }

    @Test("A cut text keeps its head in the cell, and the column keeps the table's type")
    func foldKeepsHeads() throws {
        let layout = UnloadedValueLayout(deferred: [.init(position: 1, type: .json(rawType: "JSON"), readsHead: true)])
        var rows: [[PluginCellValue]] = [
            ["1", .null, "2000000", "{\"a\": [1, 2"],
            ["2", "{}", "2", .null],
            ["3", .null, .null, .null]
        ]
        let fold = try #require(UnloadedValueFold.fold(
            columns: ["id", "doc", "__tablepro_byte_length_1", "__tablepro_head_1"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: ""), .integer(rawType: "BIGINT"), .text(rawType: "")],
            rows: &rows,
            columnMeta: nil,
            layout: layout
        ))
        #expect(fold.columns == ["id", "doc"])
        #expect(fold.columnTypes == [.integer(rawType: "INT"), .json(rawType: "JSON")])
        #expect(fold.unloadedCells == [0: [1: 2_000_000]])
        #expect(rows == [["1", "{\"a\": [1, 2"], ["2", "{}"], ["3", .null]])
    }

    @Test("A result without the planned trailing columns is left alone")
    func foldIgnoresOtherResults() {
        var rows: [[PluginCellValue]] = [["1", "a"]]
        #expect(UnloadedValueFold.fold(
            columns: ["id", "name"], columnTypes: [], rows: &rows, columnMeta: nil,
            layout: UnloadedValueLayout(deferred: [.init(position: 1, type: nil, readsHead: false)])
        ) == nil)
        var other: [[PluginCellValue]] = [[.null, "1"]]
        #expect(UnloadedValueFold.fold(
            columns: ["id", "__tablepro_byte_length_0"], columnTypes: [], rows: &other, columnMeta: nil,
            layout: nil
        ) == nil)
        #expect(other == [[.null, "1"]])
    }

    @Test("The trailing aliases follow the deferred columns' places in the select list")
    func trailingColumnsMatchSelectList() throws {
        let plan = try #require(Self.plan())
        #expect(plan.layout(for: Self.columns).trailingColumns == ["__tablepro_byte_length_2", "__tablepro_byte_length_3"])
    }

    @Test("A folded page builds rows that know which values are on the server")
    func foldedPageBuildsUnloadedRows() {
        var result = QueryFetchResult(
            columns: ["id", "data", "__tablepro_byte_length_1"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "LONGBLOB"), .integer(rawType: "BIGINT")],
            rows: [["1", .null, "70000"]],
            executionTime: 0,
            rowsAffected: 0,
            statusMessage: nil,
            isTruncated: false,
            resultColumnMeta: nil
        )
        result.foldUnloadedValues(UnloadedValueLayout(deferred: [.init(position: 1, type: nil, readsHead: false)]))
        let tableRows = TableRows.from(
            queryRows: result.rows, columns: result.columns, columnTypes: result.columnTypes,
            unloadedCells: result.unloadedCells
        )
        #expect(tableRows.columns == ["id", "data"])
        #expect(tableRows.unloadedByteCount(row: 0, column: 1) == 70_000)
        #expect(tableRows.hasUnloadedValues)
    }

    @Test("A folded page keeps the origins of the columns it keeps")
    func foldedPageKeepsColumnOrigins() {
        let id = PluginColumnOrigin(schema: "main", table: "files", column: "id")
        let data = PluginColumnOrigin(schema: "main", table: "files", column: "data")
        var fetched = QueryFetchResult(
            columns: ["id", "data", "__tablepro_byte_length_1"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "LONGBLOB"), .integer(rawType: "BIGINT")],
            rows: [["1", .null, "70000"]],
            executionTime: 0,
            rowsAffected: 0,
            statusMessage: nil,
            isTruncated: false,
            resultColumnMeta: nil
        )
        fetched.columnOrigins = [id, data, nil]
        fetched.foldUnloadedValues(UnloadedValueLayout(deferred: [.init(position: 1, type: nil, readsHead: false)]))
        #expect(fetched.columnOrigins == [id, data])
    }

    @Test("A deferred column, which the engine reports no origin for, takes the key's table")
    func foldedPageNamesDeferredOrigin() {
        let id = PluginColumnOrigin(schema: "public", table: "posts", column: "id")
        var fetched = QueryFetchResult(
            columns: ["id", "body", "__tablepro_byte_length_1", "__tablepro_head_1"],
            columnTypes: [.integer(rawType: "int4"), .text(rawType: "text"), .integer(rawType: "int4"), .text(rawType: "text")],
            rows: [["1", .null, "70000", "lorem"]],
            executionTime: 0,
            rowsAffected: 0,
            statusMessage: nil,
            isTruncated: false,
            resultColumnMeta: nil
        )
        fetched.columnOrigins = [id, nil, nil, nil]
        fetched.foldUnloadedValues(UnloadedValueLayout(deferred: [.init(position: 1, type: nil, readsHead: true)]))
        #expect(fetched.columnOrigins == [id, PluginColumnOrigin(schema: "public", table: "posts", column: "body")])
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
            "", placeholder: placeholder, nullDisplayString: "NULL"
        )
        #expect(text == ByteCountFormatter.string(fromByteCount: 5_242_880, countStyle: .file))
    }

    private static func cutText() -> TableRows {
        TableRows.from(
            queryRows: [["1", "lorem ipsum"]],
            columns: ["id", "body"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "LONGTEXT")],
            unloadedCells: [0: [1: 5_242_880]]
        )
    }

    @Test("A cut text reads NULL, and its first characters are kept beside the row for the grid")
    func cutTextReadsNull() {
        let tableRows = Self.cutText()
        let id = tableRows.rows[0].id
        #expect(tableRows.value(at: 0, column: 1) == .null)
        #expect(tableRows.unloadedHead(id, column: 1) == "lorem ipsum")
        #expect(tableRows.unloadedByteCount(row: 0, column: 1) == 5_242_880)
    }

    @Test("Loading a cut text drops its first characters with its mark")
    func fillDropsHead() {
        var tableRows = Self.cutText()
        let id = tableRows.rows[0].id
        tableRows.fillUnloaded([id: [1: .text("lorem ipsum dolor")]])
        #expect(tableRows.value(at: 0, column: 1) == .text("lorem ipsum dolor"))
        #expect(tableRows.unloadedHead(id, column: 1) == nil)
    }

    @Test("A masked column keeps no first characters, so its cut cells show only their size")
    func maskedColumnKeepsNoHead() {
        var tableRows = Self.cutText()
        let id = tableRows.rows[0].id
        tableRows.addMasks(ColumnMasks(styles: [1: .full]))
        #expect(tableRows.unloadedHead(id, column: 1) == nil)
        #expect(tableRows.unloadedByteCount(row: 0, column: 1) == 5_242_880)
    }

    @Test("The grid shows a cut text's first characters, marked as the start of a longer value")
    func placeholderShowsHead() {
        let placeholder = DataGridCellContent.placeholder(for: "lorem ipsum", unloadedByteCount: 5_242_880)
        let text = DataGridCellContent.resolvedDisplayText(
            "lorem ipsum", placeholder: placeholder, nullDisplayString: "NULL"
        )
        #expect(text == "lorem ipsum…")
    }
}
