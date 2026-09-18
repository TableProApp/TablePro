import Foundation
import TableProSpannerCore
import Testing

@Suite("SpannerBrowseRenderer")
struct SpannerBrowseRendererTests {
    private func request(
        table: String = "Singers",
        schema: String = "",
        filters: [SpannerBrowseFilter] = [],
        matchAll: Bool = true,
        sorts: [SpannerBrowseSort] = [],
        limit: Int = 100,
        offset: Int = 0
    ) -> SpannerBrowseRequest {
        SpannerBrowseRequest(
            table: table, schema: schema, columns: [], sorts: sorts, filters: filters,
            matchAll: matchAll, limit: limit, offset: offset
        )
    }

    private func whereSQL(_ filter: SpannerBrowseFilter, _ dialect: SpannerDialect) -> (sql: String, parameters: [SpannerCell]) {
        let table = dialect == .googleSQL ? "Singers" : "singers"
        let statement = SpannerBrowseRenderer.count(request(table: table, filters: [filter]), dialect: dialect)
        let prefix = "SELECT COUNT(*) FROM \(dialect.quoteIdentifier(table)) WHERE ("
        #expect(statement.sql.hasPrefix(prefix))
        #expect(statement.sql.hasSuffix(")"))
        return (String(statement.sql.dropFirst(prefix.count).dropLast()), statement.parameters)
    }

    @Test("An unfiltered browse has no parameters and known types")
    func unfiltered() {
        let statement = SpannerBrowseRenderer.select(request(), dialect: .googleSQL)
        #expect(statement.sql == "SELECT * FROM `Singers` LIMIT 100 OFFSET 0")
        #expect(statement.parameters.isEmpty)
        #expect(statement.parameterTypes?.isEmpty == true)
        let count = SpannerBrowseRenderer.count(request(), dialect: .postgreSQL)
        #expect(count.sql == "SELECT COUNT(*) FROM \"Singers\"")
    }

    @Test("Filters, sorts and paging in GoogleSQL")
    func fullGoogleSQL() {
        let statement = SpannerBrowseRenderer.select(
            request(
                filters: [SpannerBrowseFilter(column: "Name", op: "=", value: "bob"), SpannerBrowseFilter(column: "Age", op: ">", value: "60")],
                matchAll: false,
                sorts: [SpannerBrowseSort(column: "Active", ascending: false), SpannerBrowseSort(column: "Id", ascending: true)],
                limit: 3,
                offset: 1
            ),
            dialect: .googleSQL
        )
        #expect(statement.sql == "SELECT * FROM `Singers` WHERE (`Name` = @p1 OR `Age` > @p2) ORDER BY `Active` DESC, `Id` ASC LIMIT 3 OFFSET 1")
        #expect(statement.parameters == [.text("bob"), .text("60")])
        #expect(statement.parameterTypes == nil)
    }

    @Test("Filters, sorts and paging in PostgreSQL")
    func fullPostgreSQL() {
        let statement = SpannerBrowseRenderer.select(
            request(
                table: "orders",
                schema: "sales",
                filters: [SpannerBrowseFilter(column: "amt", op: ">=", value: "10"), SpannerBrowseFilter(column: "id", op: "!=", value: "3")],
                sorts: [SpannerBrowseSort(column: "amt", ascending: true)],
                limit: 50,
                offset: 100
            ),
            dialect: .postgreSQL
        )
        #expect(statement.sql == "SELECT * FROM \"sales\".\"orders\" WHERE (\"amt\" >= $1 AND \"id\" != $2) ORDER BY \"amt\" ASC LIMIT 50 OFFSET 100")
        #expect(statement.parameters == [.text("10"), .text("3")])
    }

    @Test("The count shares the filter and its parameters")
    func countMatchesSelect() {
        let filtered = request(filters: [SpannerBrowseFilter(column: "Name", op: "CONTAINS", value: "a", caseSensitive: false)])
        let select = SpannerBrowseRenderer.select(filtered, dialect: .googleSQL)
        let count = SpannerBrowseRenderer.count(filtered, dialect: .googleSQL)
        #expect(count.sql == "SELECT COUNT(*) FROM `Singers` WHERE (LOWER(CAST(`Name` AS STRING)) LIKE LOWER(@p1))")
        #expect(count.parameters == select.parameters)
        #expect(count.parameters == [.text("%a%")])
    }

    @Test("Negative paging is clamped")
    func clampsPaging() {
        let statement = SpannerBrowseRenderer.select(request(limit: -1, offset: -5), dialect: .googleSQL)
        #expect(statement.sql == "SELECT * FROM `Singers` LIMIT 0 OFFSET 0")
    }

    @Test("Comparison operators bind their value", arguments: ["=", "!=", ">", ">=", "<", "<="])
    func comparisons(op: String) {
        let google = whereSQL(SpannerBrowseFilter(column: "Age", op: op, value: "30"), .googleSQL)
        #expect(google.sql == "`Age` \(op) @p1")
        #expect(google.parameters == [.text("30")])
        let postgres = whereSQL(SpannerBrowseFilter(column: "age", op: op, value: "30"), .postgreSQL)
        #expect(postgres.sql == "\"age\" \(op) $1")
    }

    @Test("<> is written as !=")
    func notEqualSpelling() {
        #expect(whereSQL(SpannerBrowseFilter(column: "Age", op: "<>", value: "1"), .googleSQL).sql == "`Age` != @p1")
    }

    @Test("A NULL value turns equality into a null test")
    func nullEquality() {
        let equal = whereSQL(SpannerBrowseFilter(column: "Name", op: "=", value: "null"), .googleSQL)
        #expect(equal.sql == "`Name` IS NULL")
        #expect(equal.parameters.isEmpty)
        #expect(whereSQL(SpannerBrowseFilter(column: "name", op: "<>", value: " NULL "), .postgreSQL).sql == "\"name\" IS NOT NULL")
    }

    @Test("Case-insensitive equality lowers both sides")
    func caseInsensitiveEquality() {
        let google = whereSQL(SpannerBrowseFilter(column: "Name", op: "=", value: "alice", caseSensitive: false), .googleSQL)
        #expect(google.sql == "LOWER(CAST(`Name` AS STRING)) = LOWER(@p1)")
        let postgres = whereSQL(SpannerBrowseFilter(column: "name", op: "!=", value: "ALICE", caseSensitive: false), .postgreSQL)
        #expect(postgres.sql == "LOWER(CAST(\"name\" AS TEXT)) != LOWER($1)")
    }

    @Test("Pattern operators build an escaped LIKE pattern")
    func patterns() {
        let contains = whereSQL(SpannerBrowseFilter(column: "Name", op: "CONTAINS", value: "50%_\\"), .googleSQL)
        #expect(contains.sql == "CAST(`Name` AS STRING) LIKE @p1")
        #expect(contains.parameters == [.text(#"%50\%\_\\%"#)])
        let notContains = whereSQL(SpannerBrowseFilter(column: "Name", op: "NOT CONTAINS", value: "x"), .googleSQL)
        #expect(notContains.sql == "CAST(`Name` AS STRING) NOT LIKE @p1")
        #expect(notContains.parameters == [.text("%x%")])
        #expect(whereSQL(SpannerBrowseFilter(column: "Name", op: "STARTS WITH", value: "al"), .googleSQL).parameters == [.text("al%")])
        #expect(whereSQL(SpannerBrowseFilter(column: "Name", op: "ENDS WITH", value: "ce"), .googleSQL).parameters == [.text("%ce")])
    }

    @Test("PostgreSQL LIKE relies on the default backslash escape, which NOT LIKE ... ESCAPE cannot name")
    func postgresLike() {
        let sensitive = whereSQL(SpannerBrowseFilter(column: "name", op: "CONTAINS", value: "50%"), .postgreSQL)
        #expect(sensitive.sql == #"CAST("name" AS TEXT) LIKE $1"#)
        #expect(sensitive.parameters == [.text(#"%50\%%"#)])
        let insensitive = whereSQL(SpannerBrowseFilter(column: "name", op: "NOT CONTAINS", value: "li", caseSensitive: false), .postgreSQL)
        #expect(insensitive.sql == #"LOWER(CAST("name" AS TEXT)) NOT LIKE LOWER($1)"#)
        #expect(insensitive.parameters == [.text("%li%")])
    }

    @Test("A quote in a filter value never reaches the SQL text")
    func injectionIsBound() {
        let value = "x' OR TRUE --"
        for dialect in [SpannerDialect.googleSQL, .postgreSQL] {
            for op in ["=", "CONTAINS", "IN", "REGEX", ">"] {
                let rendered = whereSQL(SpannerBrowseFilter(column: "Name", op: op, value: value), dialect)
                #expect(!rendered.sql.contains("OR TRUE"))
                #expect(rendered.parameters.contains { $0 == .text(value) || $0 == .text("%\(value)%") })
            }
        }
    }

    @Test("IN lists skip empty items and turn NULL into a null test")
    func membershipEdges() {
        let withNull = whereSQL(SpannerBrowseFilter(column: "Id", op: "IN", value: "1, , NULL,2"), .googleSQL)
        #expect(withNull.sql == "(`Id` IN (@p1, @p2) OR `Id` IS NULL)")
        #expect(withNull.parameters == [.text("1"), .text("2")])
        let notInNull = whereSQL(SpannerBrowseFilter(column: "Id", op: "NOT IN", value: "null,3"), .googleSQL)
        #expect(notInNull.sql == "(`Id` NOT IN (@p1) AND `Id` IS NOT NULL)")
        let onlyNull = whereSQL(SpannerBrowseFilter(column: "Id", op: "IN", value: "NULL"), .googleSQL)
        #expect(onlyNull.sql == "`Id` IS NULL")
        let empty = whereSQL(SpannerBrowseFilter(column: "Id", op: "IN", value: " , "), .googleSQL)
        #expect(empty.sql == "FALSE")
        #expect(empty.parameters.isEmpty)
    }

    @Test("IN lists bind one parameter per trimmed value")
    func membership() {
        let inList = whereSQL(SpannerBrowseFilter(column: "Id", op: "IN", value: "1, 2 ,3"), .googleSQL)
        #expect(inList.sql == "`Id` IN (@p1, @p2, @p3)")
        #expect(inList.parameters == [.text("1"), .text("2"), .text("3")])
        let notIn = whereSQL(SpannerBrowseFilter(column: "id", op: "NOT IN", value: "1,2"), .postgreSQL)
        #expect(notIn.sql == "\"id\" NOT IN ($1, $2)")
        let insensitive = whereSQL(SpannerBrowseFilter(column: "Name", op: "IN", value: "alice, BOB", caseSensitive: false), .googleSQL)
        #expect(insensitive.sql == "LOWER(CAST(`Name` AS STRING)) IN (LOWER(@p1), LOWER(@p2))")
        #expect(insensitive.parameters == [.text("alice"), .text("BOB")])
    }

    @Test("BETWEEN prefers the second value and falls back to the first comma")
    func between() {
        let joined = whereSQL(SpannerBrowseFilter(column: "Age", op: "BETWEEN", value: "30,5,0", secondValue: "5,0"), .googleSQL)
        #expect(joined.sql == "`Age` BETWEEN @p1 AND @p2")
        #expect(joined.parameters == [.text("30"), .text("5,0")])
        let separate = whereSQL(SpannerBrowseFilter(column: "Age", op: "BETWEEN", value: "30", secondValue: "50"), .googleSQL)
        #expect(separate.parameters == [.text("30"), .text("50")])
        let fallback = whereSQL(SpannerBrowseFilter(column: "age", op: "BETWEEN", value: "30, 50"), .postgreSQL)
        #expect(fallback.sql == "\"age\" BETWEEN $1 AND $2")
        #expect(fallback.parameters == [.text("30"), .text("50")])
        #expect(whereSQL(SpannerBrowseFilter(column: "Age", op: "BETWEEN", value: "30"), .googleSQL).sql == "FALSE")
    }

    @Test("Null and emptiness tests bind nothing")
    func nullAndEmpty() {
        #expect(whereSQL(SpannerBrowseFilter(column: "Age", op: "IS NULL", value: ""), .googleSQL).sql == "`Age` IS NULL")
        #expect(whereSQL(SpannerBrowseFilter(column: "Age", op: "IS NOT NULL", value: "x"), .googleSQL).sql == "`Age` IS NOT NULL")
        let empty = whereSQL(SpannerBrowseFilter(column: "Name", op: "IS EMPTY", value: ""), .googleSQL)
        #expect(empty.sql == "(`Name` IS NULL OR CAST(`Name` AS STRING) = '')")
        #expect(empty.parameters.isEmpty)
        let notEmpty = whereSQL(SpannerBrowseFilter(column: "name", op: "IS NOT EMPTY", value: ""), .postgreSQL)
        #expect(notEmpty.sql == "(\"name\" IS NOT NULL AND CAST(\"name\" AS TEXT) != '')")
    }

    @Test("REGEX uses each dialect's matcher and an inline flag for case")
    func regex() {
        #expect(whereSQL(SpannerBrowseFilter(column: "Name", op: "REGEX", value: "^A"), .googleSQL).sql
            == "REGEXP_CONTAINS(CAST(`Name` AS STRING), @p1)")
        #expect(whereSQL(SpannerBrowseFilter(column: "Name", op: "regex", value: "^a", caseSensitive: false), .googleSQL).sql
            == "REGEXP_CONTAINS(CAST(`Name` AS STRING), CONCAT('(?i)', @p1))")
        #expect(whereSQL(SpannerBrowseFilter(column: "name", op: "REGEX", value: "^A"), .postgreSQL).sql
            == "CAST(\"name\" AS TEXT) ~ $1")
        #expect(whereSQL(SpannerBrowseFilter(column: "name", op: "REGEX", value: "^a", caseSensitive: false), .postgreSQL).sql
            == "CAST(\"name\" AS TEXT) ~ ('(?i)' || $1)")
    }

    @Test("Raw SQL is parenthesized on its own lines so a trailing comment cannot swallow the rest")
    func rawSQL() {
        let raw = whereSQL(SpannerBrowseFilter(column: "__RAW__", op: "=", value: " Age > 40 -- note "), .googleSQL)
        #expect(raw.sql == "(Age > 40 -- note\n)")
        #expect(raw.parameters.isEmpty)
        let select = SpannerBrowseRenderer.select(
            request(filters: [SpannerBrowseFilter(column: "__RAW__", op: "=", value: "Age > 40 -- note")]),
            dialect: .googleSQL
        )
        #expect(select.sql == "SELECT * FROM `Singers` WHERE ((Age > 40 -- note\n)) LIMIT 100 OFFSET 0")
        #expect(whereSQL(SpannerBrowseFilter(column: "__RAW__", op: "=", value: "  "), .googleSQL).sql == "FALSE")
    }

    @Test("An unknown operator matches nothing", arguments: ["LIKE", "~", "", "EXISTS"])
    func unknownOperator(op: String) {
        let rendered = whereSQL(SpannerBrowseFilter(column: "Name", op: op, value: "x"), .googleSQL)
        #expect(rendered.sql == "FALSE")
        #expect(rendered.parameters.isEmpty)
    }

    @Test("Operators match case-insensitively")
    func operatorCase() {
        #expect(whereSQL(SpannerBrowseFilter(column: "Name", op: "starts with", value: "a"), .googleSQL).sql
            == "CAST(`Name` AS STRING) LIKE @p1")
        #expect(whereSQL(SpannerBrowseFilter(column: "Name", op: " is null ", value: ""), .googleSQL).sql == "`Name` IS NULL")
    }

    @Test("Identifiers in filters and sorts are quoted")
    func quotedIdentifiers() {
        let statement = SpannerBrowseRenderer.select(
            request(
                filters: [SpannerBrowseFilter(column: "a`b", op: "=", value: "1")],
                sorts: [SpannerBrowseSort(column: "x` DESC, (SELECT 1)", ascending: true)]
            ),
            dialect: .googleSQL
        )
        #expect(statement.sql == #"SELECT * FROM `Singers` WHERE (`a\`b` = @p1) ORDER BY `x\` DESC, (SELECT 1)` ASC LIMIT 100 OFFSET 0"#)
    }
}

@Suite("SpannerBrowseRequest")
struct SpannerBrowseRequestTests {
    private let sample = SpannerBrowseRequest(
        table: "Orders",
        schema: "sales",
        columns: ["Id", "Amt"],
        sorts: [SpannerBrowseSort(column: "Amt", ascending: false)],
        filters: [SpannerBrowseFilter(column: "Amt", op: "BETWEEN", value: "1", secondValue: "9", caseSensitive: false)],
        matchAll: false,
        limit: 200,
        offset: 400
    )

    @Test("The descriptor round-trips")
    func roundTrip() {
        let encoded = sample.encoded()
        #expect(encoded.hasPrefix("SPANNER_BROWSE:"))
        #expect(SpannerBrowseRequest.decode(encoded) == sample)
        #expect(SpannerBrowseRequest.decode("\n  " + encoded + " \n") == sample)
    }

    @Test("Encoding is deterministic")
    func deterministic() {
        let decoded = SpannerBrowseRequest.decode(sample.encoded())
        #expect(decoded?.encoded() == sample.encoded())
    }

    @Test("Anything without the tag or with a broken payload is not a descriptor")
    func rejects() {
        #expect(SpannerBrowseRequest.tag == "SPANNER_BROWSE:")
        #expect(SpannerBrowseRequest.decode("SELECT * FROM t") == nil)
        #expect(SpannerBrowseRequest.decode("SPANNER_BROWSE:not base64!") == nil)
        #expect(SpannerBrowseRequest.decode("SPANNER_BROWSE:" + Data("{}".utf8).base64EncodedString()) == nil)
        #expect(SpannerBrowseRequest.decode("x" + sample.encoded()) == nil)
    }
}
