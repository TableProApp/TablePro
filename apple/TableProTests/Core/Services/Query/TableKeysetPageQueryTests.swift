//
//  TableKeysetPageQueryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableKeysetPageQueryTests {
    private static var builder: TableQueryBuilder {
        TableQueryBuilder(
            databaseType: .postgresql,
            dialect: SQLDialectDescriptor(
                identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
                regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
                likeEscapeStyle: .explicit, paginationStyle: .limit
            ),
            pagination: .offset,
            dialectQuote: { "\"\($0)\"" }
        )
    }

    private static func byKey(_ names: [String], _ direction: SortDirection = .ascending) -> SortState {
        SortState(
            columns: names.enumerated().map { SortColumn(columnIndex: $0.offset, direction: direction, columnName: $0.element) },
            source: .defaultSort
        )
    }

    private static func seek(
        _ key: [PluginCellValue]?,
        columns: [String] = ["id"],
        types: [ColumnType?] = [.integer(rawType: "integer")],
        direction: SortDirection = .ascending,
        backward: Bool = false
    ) -> TableKeysetSeek {
        TableKeysetSeek(columns: columns, columnTypes: types, direction: direction, key: key, readsBackward: backward)
    }

    private static func query(
        _ seek: TableKeysetSeek,
        sort: SortState? = nil,
        filters: [TableFilter] = [],
        logicMode: FilterLogicMode = .and,
        columns: [String] = ["id", "name"],
        limit: Int = 100
    ) -> String? {
        builder.buildKeysetPageQuery(
            tableName: "users", filters: filters, logicMode: logicMode,
            sortState: sort ?? byKey(seek.columns, seek.direction),
            columns: columns, columnTypes: [.integer(rawType: "integer"), .text(rawType: "text")],
            limit: limit, seek: seek
        )
    }

    @Test("The next page seeks past the last key, with no offset")
    func nextPageSeeksPastTheKey() {
        #expect(Self.query(Self.seek(["100"])) == """
            SELECT * FROM "users" WHERE "id" > 100 ORDER BY "id" ASC LIMIT 100 OFFSET 0
            """)
    }

    @Test("The previous page reads backward from the first key")
    func previousPageReadsBackward() {
        #expect(Self.query(Self.seek(["201"], backward: true)) == """
            SELECT * FROM "users" WHERE "id" < 201 ORDER BY "id" DESC LIMIT 100 OFFSET 0
            """)
    }

    @Test("The last page reads backward from the end, as many rows as the page holds")
    func lastPageReadsTheTail() {
        #expect(Self.query(Self.seek(nil, backward: true), limit: 37) == """
            SELECT * FROM "users" ORDER BY "id" DESC LIMIT 37 OFFSET 0
            """)
    }

    @Test("A descending key seeks below the edge")
    func descendingKey() {
        #expect(Self.query(Self.seek(["100"], direction: .descending)) == """
            SELECT * FROM "users" WHERE "id" < 100 ORDER BY "id" DESC LIMIT 100 OFFSET 0
            """)
    }

    @Test("A composite key compares as one row value, text quoted and escaped")
    func compositeKey() {
        let seek = Self.seek(
            ["7", "o'neil"], columns: ["id", "name"],
            types: [.integer(rawType: "integer"), .text(rawType: "text")]
        )
        #expect(Self.query(seek) == """
            SELECT * FROM "users" WHERE ("id", "name") > (7, 'o''neil') ORDER BY "id" ASC, "name" ASC LIMIT 100 OFFSET 0
            """)
    }

    @Test("Filters match any keep their own parentheses beside the seek")
    func filtersKeepTheirGrouping() throws {
        func equals(_ value: String) -> TableFilter {
            var filter = TableFilter()
            filter.columnName = "name"
            filter.filterOperator = .equal
            filter.value = value
            filter.isEnabled = true
            return filter
        }
        let query = try #require(Self.query(Self.seek(["5"]), filters: [equals("a"), equals("b")], logicMode: .or))
        #expect(query.contains("WHERE (\"name\" = 'a' OR \"name\" = 'b') AND \"id\" > 5 ORDER BY"))
    }

    @Test("A whole decimal key seeks as written")
    func wholeDecimalKey() {
        #expect(Self.query(Self.seek(["42.00"], types: [.decimal(rawType: "DECIMAL(10,2)")])) == """
            SELECT * FROM "users" WHERE "id" > 42.00 ORDER BY "id" ASC LIMIT 100 OFFSET 0
            """)
    }

    @Test("A key with no exact literal, or an order that is not the key, pages by offset")
    func refusesWhatCannotSeek() {
        #expect(Self.query(Self.seek(["1.5"], types: [.decimal(rawType: "double precision")])) == nil)
        #expect(Self.query(Self.seek([.bytes(Data([1]))], types: [.blob(rawType: "bytea")])) == nil)
        #expect(Self.query(Self.seek(["small"], types: [.enumType(rawType: "ENUM('small','large')", values: nil)])) == nil)
        #expect(Self.query(Self.seek(["30"], types: [.text(rawType: "")])) == nil)
        #expect(Self.query(Self.seek(["30"], types: [.text(rawType: "any")])) == nil)
        #expect(Self.query(Self.seek(["0.3"], types: [.decimal(rawType: "NUMERIC")])) == nil)
        #expect(Self.query(Self.seek(["1\u{301}"], types: [.decimal(rawType: "NUMERIC")])) == nil)
        #expect(Self.query(Self.seek(["2460640.12345679"], types: [.date(rawType: "DATE")])) == nil)
        #expect(Self.query(Self.seek(["2024-11-03 01:30:00"], types: [.timestamp(rawType: "TIMESTAMP")])) == nil)
        #expect(Self.query(Self.seek(["a\u{0}b"], types: [.text(rawType: "TEXT")])) == nil)
        #expect(Self.query(Self.seek(["1 OR 1=1"])) == nil)
        #expect(Self.query(Self.seek(["5"]), sort: Self.byKey(["name"])) == nil)
        #expect(Self.query(Self.seek(["5"]), sort: Self.byKey(["id"], .descending)) == nil)
    }
}
