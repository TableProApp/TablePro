//
//  TableKeysetPageQueryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// A PostgreSQL session whose `standard_conforming_strings` is off reads a backslash in a quoted literal as an escape.
private final class BackslashSession: PluginDriverStub, @unchecked Sendable {
    let readsBackslashEscapes: Bool

    init(readsBackslashEscapes: Bool) {
        self.readsBackslashEscapes = readsBackslashEscapes
    }

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { "public" }
    var serverVersion: String? { nil }
    var sessionLexicalState: PluginSessionLexicalState? {
        PluginSessionLexicalState(
            determined: [.backslashEscapesInSingleQuotes],
            enabled: readsBackslashEscapes ? [.backslashEscapesInSingleQuotes] : []
        )
    }
}

struct TableKeysetPageQueryTests {
    private static let postgresDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit
    )

    private static func builder(session: (any DatabaseDriver)? = nil) -> TableQueryBuilder {
        TableQueryBuilder(
            databaseType: .postgresql,
            dialect: postgresDialect,
            pagination: .offset,
            dialectQuote: { "\"\($0)\"" },
            sessionDriver: session
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
        limit: Int = 100,
        builder: TableQueryBuilder = Self.builder()
    ) -> KeyedPageStatement? {
        builder.buildKeysetPageQuery(
            tableName: "users", filters: filters, logicMode: logicMode,
            sortState: sort ?? byKey(seek.columns, seek.direction),
            columns: columns, columnTypes: [.integer(rawType: "integer"), .text(rawType: "text")],
            limit: limit, seek: seek
        )
    }

    private static func equals(_ value: String) -> TableFilter {
        var filter = TableFilter()
        filter.columnName = "name"
        filter.filterOperator = .equal
        filter.value = value
        filter.isEnabled = true
        return filter
    }

    @Test("The next page seeks past the last key, sent as a bound value")
    func nextPageSeeksPastTheKey() {
        #expect(Self.query(Self.seek(["100"])) == KeyedPageStatement(
            sql: #"SELECT * FROM "users" WHERE "id" > $1 ORDER BY "id" ASC LIMIT 100 OFFSET 0"#,
            keyValues: ["100"],
            readsBackward: false
        ))
    }

    @Test("The previous page reads backward from the first key")
    func previousPageReadsBackward() {
        #expect(Self.query(Self.seek(["201"], backward: true)) == KeyedPageStatement(
            sql: #"SELECT * FROM "users" WHERE "id" < $1 ORDER BY "id" DESC LIMIT 100 OFFSET 0"#,
            keyValues: ["201"],
            readsBackward: true
        ))
    }

    @Test("The last page reads backward from the end, as many rows as the page holds")
    func lastPageReadsTheTail() {
        #expect(Self.query(Self.seek(nil, backward: true), limit: 37) == KeyedPageStatement(
            sql: #"SELECT * FROM "users" ORDER BY "id" DESC LIMIT 37 OFFSET 0"#,
            keyValues: [],
            readsBackward: true
        ))
    }

    @Test("A descending key seeks below the edge")
    func descendingKey() {
        #expect(Self.query(Self.seek(["100"], direction: .descending))?.sql == """
            SELECT * FROM "users" WHERE "id" < $1 ORDER BY "id" DESC LIMIT 100 OFFSET 0
            """)
    }

    @Test("A composite key compares as one row value, each part its own bound value")
    func compositeKey() {
        let seek = Self.seek(
            ["7", "o'neil"], columns: ["id", "name"],
            types: [.integer(rawType: "integer"), .text(rawType: "text")]
        )
        #expect(Self.query(seek) == KeyedPageStatement(
            sql: #"SELECT * FROM "users" WHERE ("id", "name") > ($1, $2) ORDER BY "id" ASC, "name" ASC LIMIT 100 OFFSET 0"#,
            keyValues: ["7", "o'neil"],
            readsBackward: false
        ))
    }

    @Test("An engine that binds with question marks gets question marks")
    func questionMarkPlaceholders() {
        let mysql = TableQueryBuilder(
            databaseType: .mysql,
            dialect: SQLDialectDescriptor(
                identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
                regexSyntax: .regexp, booleanLiteralStyle: .numeric,
                likeEscapeStyle: .implicit, paginationStyle: .limit
            ),
            pagination: .offset,
            dialectQuote: { "`\($0)`" }
        )
        let seek = Self.seek(
            ["7", "b"], columns: ["id", "name"],
            types: [.integer(rawType: "INT"), .text(rawType: "VARCHAR(20)")]
        )
        #expect(Self.query(seek, builder: mysql)?.sql == """
            SELECT * FROM `users` WHERE (`id`, `name`) > (?, ?) ORDER BY `id` ASC, `name` ASC LIMIT 100 OFFSET 0
            """)
    }

    // The page may run on a pooled connection whose `standard_conforming_strings` differs from the browsing one, so a
    // key spliced with one session's escaping could close its literal early on the other and run the rest as SQL.
    @Test("A key holding a quote and a backslash never reaches the statement text, whatever the session escapes", arguments: [
        true, false
    ])
    func injectionThroughAQuoteStaysAValue(readsBackslashEscapes: Bool) throws {
        let key = #"x\' OR 1=1 --"#
        let session = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql),
            pluginDriver: BackslashSession(readsBackslashEscapes: readsBackslashEscapes)
        )
        let seek = Self.seek([.text(key)], columns: ["name"], types: [.text(rawType: "text")])
        let statement = try #require(Self.query(seek, builder: Self.builder(session: session)))
        #expect(statement.sql == #"SELECT * FROM "users" WHERE "name" > $1 ORDER BY "name" ASC LIMIT 100 OFFSET 0"#)
        #expect(statement.keyValues == [key])
        #expect(!statement.sql.contains("OR 1=1"))
    }

    @Test("Filters match any keep their own parentheses beside the seek")
    func filtersKeepTheirGrouping() throws {
        let statement = try #require(
            Self.query(Self.seek(["5"]), filters: [Self.equals("a"), Self.equals("b")], logicMode: .or)
        )
        #expect(statement.sql.contains("WHERE (\"name\" = 'a' OR \"name\" = 'b') AND \"id\" > $1 ORDER BY"))
        #expect(statement.keyValues == ["5"])
    }

    @Test("A raw condition keeps the offset, since a marker in it would take the key's place")
    func rawConditionKeepsTheOffset() {
        #expect(Self.query(Self.seek(["5"]), filters: [TableFilter.rawCondition("name = '?'")]) == nil)
    }

    @Test("A decimal key of digits alone seeks")
    func wholeDecimalKey() {
        #expect(Self.query(Self.seek(["42"], types: [.decimal(rawType: "DECIMAL(10,0)")]))?.keyValues == ["42"])
    }

    // An older SQLite prints a REAL near a whole number as `1.0`, so `> 1.0` reads the edge row again.
    @Test("A number printed with a point or an exponent keeps the offset, in any column SQLite may keep a REAL in")
    func printedRealsKeepTheOffset() {
        #expect(Self.query(Self.seek(["42.00"], types: [.decimal(rawType: "DECIMAL(10,2)")])) == nil)
        #expect(Self.query(Self.seek(["1.0"], types: [.decimal(rawType: "NUMERIC")])) == nil)
        #expect(Self.query(Self.seek(["1.0"], types: [.integer(rawType: "INTEGER")])) == nil)
        #expect(Self.query(Self.seek(["3.0"], types: [.date(rawType: "DATE")])) == nil)
        #expect(Self.query(Self.seek(["1e5"], types: [.text(rawType: "STRING")])) == nil)
        #expect(Self.query(Self.seek(["1234567890123456"], types: [.decimal(rawType: "NUMERIC")])) == nil)
        #expect(Self.query(Self.seek(["20240102"], types: [.date(rawType: "DATE")]))?.keyValues == ["20240102"])
    }

    // `é` written as one scalar and as `e` with a combining accent are equal to Swift and two columns to the engine.
    @Test("A sort column spelled with other scalars than the key keeps the offset")
    func normalizationSpellingsKeepTheOffset() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        let seek = Self.seek(["5"], columns: [composed])
        #expect(Self.query(seek, sort: Self.byKey([decomposed])) == nil)
        #expect(Self.query(seek, sort: Self.byKey([composed])) != nil)
    }

    @Test("A key with no exact form, or an order that is not the key, pages by offset")
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
