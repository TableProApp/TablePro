import Foundation
@testable import TableProInfluxDBCore
import Testing

private func whereClause(
    _ filter: InfluxFilter,
    kind: InfluxColumnKind? = nil,
    language: InfluxQueryLanguage
) -> String? {
    let kinds = kind.map { [filter.column: $0] } ?? [:]
    let query = InfluxGridQuery(measurement: "cpu", filters: [filter], shape: .all)
    guard let statement = query.statement(language: language, kinds: kinds) else { return nil }
    let head = InfluxStatement.marked(#"SELECT * FROM "cpu" WHERE "#, language: language)
    return statement.hasPrefix(head) ? String(statement.dropFirst(head.count)) : statement
}

struct InfluxGridQueryTests {
    private let page = InfluxGridQuery(
        measurement: "cpu",
        projection: ["time", "host", "usage"],
        sorts: [InfluxSort(column: "usage", ascending: true), InfluxSort(column: "host", ascending: false)],
        shape: .page(limit: 50, offset: 100)
    )

    @Test func anSQLPageProjectsNamedColumnsAndSortsByAnyColumn() {
        #expect(page.statement(language: .sql, kinds: [:])
            == "-- sql\n" + #"SELECT "time", "host", "usage" FROM "cpu" ORDER BY "usage" ASC, "host" DESC LIMIT 50 OFFSET 100"#)
    }

    @Test func anInfluxQLPageSelectsEverythingAndKeepsNewestFirstForAnotherColumnsSort() {
        #expect(page.statement(language: .influxQL, kinds: [:])
            == "-- influxql\n" + #"SELECT * FROM "cpu" ORDER BY time DESC LIMIT 50 OFFSET 100"#)
    }

    @Test func anInfluxQLPageSortsByTimeAscending() {
        let query = InfluxGridQuery(
            measurement: "cpu",
            sorts: [InfluxSort(column: "time", ascending: true)],
            shape: .page(limit: 10, offset: 0)
        )
        #expect(query.statement(language: .influxQL, kinds: [:])
            == "-- influxql\n" + #"SELECT * FROM "cpu" ORDER BY time ASC LIMIT 10 OFFSET 0"#)
    }

    @Test func anUnsortedSQLPageIsNewestFirst() {
        let query = InfluxGridQuery(measurement: "cpu", shape: .page(limit: 10, offset: 0))
        #expect(query.statement(language: .sql, kinds: [:])
            == "-- sql\n" + #"SELECT * FROM "cpu" ORDER BY time DESC LIMIT 10 OFFSET 0"#)
    }

    @Test func aCountKeepsTheFiltersAndDropsOrderAndLimit() {
        let query = InfluxGridQuery(
            measurement: "cpu",
            projection: ["host"],
            filters: [InfluxFilter(column: "host", op: "=", value: "a")],
            sorts: [InfluxSort(column: "time", ascending: true)],
            shape: .count
        )
        #expect(query.statement(language: .sql, kinds: ["host": .tag])
            == "-- sql\n" + #"SELECT COUNT(*) FROM "cpu" WHERE "host" = 'a'"#)
        #expect(query.statement(language: .influxQL, kinds: ["host": .tag])
            == "-- influxql\n" + #"SELECT COUNT(*) FROM "cpu" WHERE "host" = 'a'"#)
    }

    @Test func allRowsHaveNeitherOrderNorLimit() {
        let query = InfluxGridQuery(
            measurement: "cpu",
            projection: ["host"],
            filters: [InfluxFilter(column: "host", op: "=", value: "a")],
            sorts: [InfluxSort(column: "host", ascending: true)],
            shape: .all
        )
        #expect(query.statement(language: .sql, kinds: [:])
            == "-- sql\n" + #"SELECT "host" FROM "cpu" WHERE "host" = 'a'"#)
    }

    @Test func matchingAnyFilterJoinsWithOr() {
        let query = InfluxGridQuery(
            measurement: "cpu",
            filters: [
                InfluxFilter(column: "host", op: "=", value: "a"),
                InfluxFilter(column: "usage", op: ">", value: "5"),
            ],
            matchesAll: false,
            shape: .all
        )
        #expect(query.statement(language: .influxQL, kinds: ["host": .tag, "usage": .number])
            == "-- influxql\n" + #"SELECT * FROM "cpu" WHERE "host" = 'a' OR "usage" > 5"#)
    }

    @Test func aFilterWithNoMeaningMakesNoStatement() {
        let query = InfluxGridQuery(
            measurement: "cpu",
            filters: [InfluxFilter(column: "usage", op: "CONTAINS", value: "7")],
            shape: .page(limit: 10, offset: 0)
        )
        #expect(query.statement(language: .sql, kinds: ["usage": .number]) == nil)
    }

    @Test(arguments: [InfluxQueryLanguage.sql, .influxQL])
    func aTagQuotesANumericValue(language: InfluxQueryLanguage) {
        let filter = InfluxFilter(column: "zone", op: "=", value: "1")
        #expect(whereClause(filter, kind: .tag, language: language) == #""zone" = '1'"#)
    }

    @Test(arguments: [InfluxQueryLanguage.sql, .influxQL])
    func aNumberLeavesANumericValueBare(language: InfluxQueryLanguage) {
        let filter = InfluxFilter(column: "usage", op: "=", value: "7")
        #expect(whereClause(filter, kind: .number, language: language) == #""usage" = 7"#)
    }

    @Test(arguments: [("7", #""x" = 7"#), ("a", #""x" = 'a'"#), ("true", #""x" = true"#)])
    func anUnknownColumnGuessesFromTheValue(value: String, condition: String) {
        let filter = InfluxFilter(column: "x", op: "=", value: value)
        #expect(whereClause(filter, language: .influxQL) == condition)
    }

    @Test func notEqualSpelledTheSQLWayBecomesBangEquals() {
        let filter = InfluxFilter(column: "host", op: "<>", value: "a")
        #expect(whereClause(filter, kind: .tag, language: .influxQL) == #""host" != 'a'"#)
    }

    @Test func inIsAListInSQLAndAnOrChainInInfluxQL() {
        let filter = InfluxFilter(column: "host", op: "IN", value: "a, b")
        #expect(whereClause(filter, kind: .tag, language: .sql) == #""host" IN ('a', 'b')"#)
        #expect(whereClause(filter, kind: .tag, language: .influxQL) == #"("host" = 'a' OR "host" = 'b')"#)
    }

    @Test func notInIsAListInSQLAndAnAndChainInInfluxQL() {
        let filter = InfluxFilter(column: "host", op: "NOT IN", value: "a, b")
        #expect(whereClause(filter, kind: .tag, language: .sql) == #""host" NOT IN ('a', 'b')"#)
        #expect(whereClause(filter, kind: .tag, language: .influxQL) == #"("host" != 'a' AND "host" != 'b')"#)
    }

    @Test func anEmptyInListMakesNoStatement() {
        let filter = InfluxFilter(column: "host", op: "IN", value: " , ")
        #expect(whereClause(filter, kind: .tag, language: .sql) == nil)
    }

    @Test(arguments: [InfluxQueryLanguage.sql, .influxQL])
    func betweenIsTwoBounds(language: InfluxQueryLanguage) {
        let filter = InfluxFilter(column: "usage", op: "BETWEEN", value: "1", secondValue: "9")
        #expect(whereClause(filter, kind: .number, language: language) == #"("usage" >= 1 AND "usage" <= 9)"#)
    }

    @Test func betweenWithoutAnUpperBoundMakesNoStatement() {
        let filter = InfluxFilter(column: "usage", op: "BETWEEN", value: "1")
        #expect(whereClause(filter, kind: .number, language: .sql) == nil)
    }

    @Test(arguments: [
        ("CONTAINS", "a.b(c)", #""note" ~ 'a\.b\(c\)'"#, #""note" =~ /a\.b\(c\)/"#),
        ("STARTS WITH", "x+", #""note" ~ '^x\+'"#, #""note" =~ /^x\+/"#),
        ("ENDS WITH", "x$", #""note" ~ 'x\$$'"#, #""note" =~ /x\$$/"#),
        ("NOT CONTAINS", "[a]", #""note" !~ '\[a\]'"#, #""note" !~ /\[a\]/"#),
        ("CONTAINS", "a/b", #""note" ~ 'a/b'"#, #""note" =~ /a\x{2f}b/"#),
    ])
    func textMatchingEscapesRegexMetacharacters(op: String, value: String, sql: String, influxQL: String) {
        let filter = InfluxFilter(column: "note", op: op, value: value)
        #expect(whereClause(filter, kind: .text, language: .sql) == sql)
        #expect(whereClause(filter, kind: .text, language: .influxQL) == influxQL)
    }

    @Test func caseInsensitiveMatchingAddsTheFlag() {
        let filter = InfluxFilter(column: "host", op: "CONTAINS", value: "A", isCaseSensitive: false)
        #expect(whereClause(filter, kind: .tag, language: .sql) == #""host" ~ '(?i)A'"#)
        #expect(whereClause(filter, kind: .tag, language: .influxQL) == #""host" =~ /(?i)A/"#)
    }

    @Test(arguments: [
        ("CONTAINS", InfluxColumnKind.number),
        ("STARTS WITH", .number),
        ("ENDS WITH", .boolean),
        ("REGEX", .number),
        ("NOT CONTAINS", .boolean),
    ])
    func textMatchingOnANumberOrBooleanMakesNoStatement(op: String, kind: InfluxColumnKind) {
        let filter = InfluxFilter(column: "usage", op: op, value: "7")
        #expect(whereClause(filter, kind: kind, language: .sql) == nil)
        #expect(whereClause(filter, kind: kind, language: .influxQL) == nil)
    }

    @Test(arguments: [nil, .tag, .text, .number, .boolean] as [InfluxColumnKind?])
    func nullTestsAreNativeInSQL(kind: InfluxColumnKind?) {
        #expect(whereClause(InfluxFilter(column: "x", op: "IS NULL", value: ""), kind: kind, language: .sql)
            == #""x" IS NULL"#)
        #expect(whereClause(InfluxFilter(column: "x", op: "IS NOT NULL", value: ""), kind: kind, language: .sql)
            == #""x" IS NOT NULL"#)
    }

    @Test(arguments: [nil, .tag] as [InfluxColumnKind?])
    func nullTestsOnAnInfluxQLTagCompareWithEmpty(kind: InfluxColumnKind?) {
        #expect(whereClause(InfluxFilter(column: "zone", op: "IS NULL", value: ""), kind: kind, language: .influxQL)
            == #""zone" = ''"#)
        #expect(whereClause(InfluxFilter(column: "zone", op: "IS NOT NULL", value: ""), kind: kind, language: .influxQL)
            == #""zone" != ''"#)
    }

    @Test(arguments: [InfluxColumnKind.text, .number, .boolean])
    func nullTestsOnAnInfluxQLFieldMakeNoStatement(kind: InfluxColumnKind) {
        #expect(whereClause(InfluxFilter(column: "note", op: "IS NULL", value: ""), kind: kind, language: .influxQL)
            == nil)
        #expect(whereClause(InfluxFilter(column: "note", op: "IS NOT NULL", value: ""), kind: kind, language: .influxQL)
            == nil)
    }

    @Test func emptyTestsOnTextCompareWithEmpty() {
        #expect(whereClause(InfluxFilter(column: "note", op: "IS EMPTY", value: ""), kind: .text, language: .sql)
            == #""note" = ''"#)
        #expect(whereClause(InfluxFilter(column: "note", op: "IS NOT EMPTY", value: ""), kind: .text, language: .influxQL)
            == #""note" != ''"#)
    }

    @Test func anEmptyTestOnANumberMakesNoStatement() {
        let filter = InfluxFilter(column: "usage", op: "IS EMPTY", value: "")
        #expect(whereClause(filter, kind: .number, language: .sql) == nil)
        #expect(whereClause(filter, kind: .number, language: .influxQL) == nil)
    }

    @Test func theRowCountIsTheLargestCountColumn() {
        let table = InfluxResultTable(
            columns: ["time", "count_idle", "count_note", "count_usage"],
            typeNames: ["timestamp", "integer", "integer", "integer"],
            rows: [["1970-01-01T00:00:00Z", "2", "5", "3"]]
        )
        #expect(InfluxGridQuery.rowCount(from: table) == 5)
    }

    @Test func theSQLRowCountIsItsOneCountColumn() {
        let table = InfluxResultTable(columns: ["count(*)"], typeNames: ["integer"], rows: [["42"]])
        #expect(InfluxGridQuery.rowCount(from: table) == 42)
    }

    @Test func noRowsCountsZero() {
        let table = InfluxResultTable(columns: ["count(*)"], typeNames: ["integer"], rows: [])
        #expect(InfluxGridQuery.rowCount(from: table) == 0)
        #expect(InfluxGridQuery.rowCount(from: .empty) == 0)
    }

    @Test func identifiersAreQuotedPerLanguage() {
        #expect(InfluxGridQuery.quoteIdentifier(#"a"b"#, language: .sql) == #""a""b""#)
        #expect(InfluxGridQuery.quoteIdentifier(#"a"b"#, language: .influxQL) == #""a\"b""#)
        #expect(InfluxGridQuery.quoteIdentifier(#"a\b"#, language: .influxQL) == #""a\\b""#)
    }

    @Test func stringsAreQuotedPerLanguage() {
        #expect(InfluxGridQuery.stringLiteral("it's", language: .sql) == "'it''s'")
        #expect(InfluxGridQuery.stringLiteral("it's", language: .influxQL) == #"'it\'s'"#)
        #expect(InfluxGridQuery.stringLiteral(#"a\b"#, language: .influxQL) == #"'a\\b'"#)
    }

    @Test func theMeasurementNameIsQuotedInTheStatement() {
        let query = InfluxGridQuery(measurement: #"we"ird"#, shape: .count)
        #expect(query.statement(language: .sql, kinds: [:]) == "-- sql\n" + #"SELECT COUNT(*) FROM "we""ird""#)
        #expect(query.statement(language: .influxQL, kinds: [:]) == "-- influxql\n" + #"SELECT COUNT(*) FROM "we\"ird""#)
    }

    @Test(arguments: [
        ("a/b", #"a\x{2f}b"#),
        (#"a\"#, #"a\x{5c}"#),
        (#"a\/b"#, #"a\x{2f}b"#),
        (#"a\\b"#, #"a\x{5c}b"#),
        (#"\d+"#, #"\d+"#),
        ("\u{600}/", #"\x{600}\x{2f}"#),
        ("\u{600}\\", #"\x{600}\x{5c}"#),
        ("a\nb", #"a\x{a}b"#),
        (#"x\Qé.*/\Ey"#, #"x\x{e9}\.\*\x{2f}y"#),
        (#"\Qa+b"#, #"a\+b"#),
    ])
    func anInfluxQLRegexBodyHoldsNoSlashAndNoTrailingBackslash(pattern: String, body: String) {
        #expect(InfluxGridQuery.influxQLRegexBody(pattern) == body)
    }

    @Test func filterValuesCannotCloseAnInfluxQLRegexEarly() throws {
        let query = InfluxGridQuery(
            measurement: "cpu",
            filters: [
                InfluxFilter(column: "note", op: "CONTAINS", value: "\\"),
                InfluxFilter(column: "note", op: "CONTAINS", value: "; DELETE FROM cpu --"),
                InfluxFilter(column: "note", op: "REGEX", value: "\\/; DROP MEASUREMENT cpu --"),
            ],
            shape: .page(limit: 10, offset: 0)
        )
        let text = try #require(query.statement(language: .influxQL, kinds: ["note": .text], marked: false))
        #expect(text.unicodeScalars.filter { $0 == "/" }.count == 6)
        #expect(!text.contains("\\/"))
    }

    @Test func aCombiningMarkCannotHideASlashOrAQuote() throws {
        let value = "\u{0600}/ GROUP BY /\u{0301}'\u{0600}/; DROP MEASUREMENT cpu --'"
        let body = InfluxGridQuery.influxQLRegexBody(InfluxGridQuery.escapedRegex(value))
        #expect(!body.unicodeScalars.contains("/"))
        #expect(body.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(InfluxGridQuery.stringLiteral("a'\u{301}", language: .influxQL) == "'a\\'\u{301}'")
        #expect(InfluxGridQuery.stringLiteral("a'\u{301}", language: .sql) == "'a''\u{301}'")
        #expect(InfluxGridQuery.quoteIdentifier("a\"\u{301}", language: .sql) == "\"a\"\"\u{301}\"")
    }

    @Test func anUnmarkedPageIsTheInfluxQLForm() {
        let query = InfluxGridQuery(measurement: "cpu", projection: ["time", "host"], shape: .page(limit: 10, offset: 0))
        #expect(query.statement(language: .influxQL, kinds: [:], marked: false)
            == #"SELECT * FROM "cpu" ORDER BY time DESC LIMIT 10 OFFSET 0"#)
    }

    @Test(arguments: [("-1", "-1"), (".5", ".5"), ("5.", "5."), ("1e5", "'1e5'"), ("1\u{0};--", "'1\u{0};--'"), ("٣", "'٣'")])
    func onlyPlainNumbersGoOutUnquoted(value: String, literal: String) {
        #expect(InfluxGridQuery.literal(value, kind: .number, language: .influxQL) == literal)
    }
}
