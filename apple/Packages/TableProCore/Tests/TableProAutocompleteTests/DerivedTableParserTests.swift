import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

private extension DerivedTableParser {
    func parse(_ statement: String, cursor: Int? = nil, grammar: SQLLexicalGrammar = .ansi) -> [DerivedTable] {
        let text = statement as NSString
        let position = cursor ?? text.length
        let lexed = SQLContextAnalyzer.lex(text, cursor: position, grammar: grammar)
        return visibleTables(in: SQLContextAnalyzer.tokens(of: lexed, grammar: grammar), cursor: position)
    }
}

struct DerivedTableParserTests {
    let parser = DerivedTableParser()

    private func table(_ tables: [DerivedTable], alias: String) -> DerivedTable? {
        tables.first { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }
    }

    private func starTables(_ table: DerivedTable?) -> [String] {
        table?.projection.tables.map { [$0.schema, $0.name].compactMap { $0 }.joined(separator: ".") } ?? []
    }

    @Test("Resolves the reported derived-table join")
    func resolvesReportedQuery() {
        let query = """
        SELECT YEAR, hs.country, happiness_score, ahs.avg_happiness_score
        FROM happiness_scores hs
        LEFT JOIN (
          SELECT country, AVG(happiness_score) AS avg_happiness_score
          FROM happiness_scores
          GROUP BY country
        ) ahs
          ON hs.country = ahs.country;
        """
        let ahs = table(parser.parse(query), alias: "ahs")
        #expect(ahs?.columns == ["country", "avg_happiness_score"])
    }

    @Test("Derived table in FROM clause")
    func derivedTableInFrom() {
        let query = "SELECT * FROM (SELECT id, name FROM users) u"
        #expect(table(parser.parse(query), alias: "u")?.columns == ["id", "name"])
    }

    @Test("Derived table with AS keyword before alias")
    func derivedTableWithAsAlias() {
        let query = "SELECT * FROM (SELECT id FROM users) AS u"
        #expect(table(parser.parse(query), alias: "u")?.columns == ["id"])
    }

    @Test("Derived table in a comma-separated FROM list")
    func derivedTableInFromList() {
        let query = "SELECT * FROM orders o, (SELECT total FROM payments) p"
        #expect(table(parser.parse(query), alias: "p")?.columns == ["total"])
    }

    @Test("Qualified column keeps only the trailing identifier")
    func qualifiedColumn() {
        let query = "SELECT * FROM (SELECT u.id, u.email FROM users u) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["id", "email"])
    }

    @Test("SELECT star names no columns itself and leaves its table to the catalog")
    func selectStarLeavesItsTableToTheCatalog() {
        let d = table(parser.parse("SELECT * FROM (SELECT * FROM users) d"), alias: "d")
        #expect(d?.columns.isEmpty == true)
        #expect(starTables(d) == ["users"])
    }

    @Test("Qualified star is skipped")
    func qualifiedStarSkipped() {
        let query = "SELECT * FROM (SELECT u.*, u.id FROM users u) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["id"])
    }

    @Test("Unaliased expressions are skipped")
    func unaliasedExpressionSkipped() {
        let query = "SELECT * FROM (SELECT name, COUNT(*) FROM users GROUP BY name) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["name"])
    }

    @Test("Nested subquery exposes only the outer alias")
    func nestedSubquery() {
        let query = "SELECT * FROM (SELECT a FROM (SELECT id AS a FROM t) inner_q) outer_q"
        let tables = parser.parse(query)
        #expect(table(tables, alias: "outer_q")?.columns == ["a"])
        #expect(table(tables, alias: "inner_q") == nil)
    }

    @Test("CTE columns come from its SELECT list")
    func cteColumns() {
        let query = "WITH totals AS (SELECT country, SUM(score) AS total FROM s GROUP BY country) SELECT * FROM totals"
        #expect(table(parser.parse(query), alias: "totals")?.columns == ["country", "total"])
    }

    @Test("CTE explicit column list overrides the SELECT list")
    func cteExplicitColumnList() {
        let query = "WITH totals (region, amount) AS (SELECT country, SUM(score) FROM s GROUP BY country) SELECT * FROM totals"
        #expect(table(parser.parse(query), alias: "totals")?.columns == ["region", "amount"])
    }

    @Test("Multiple CTEs are each resolved")
    func multipleCtes() {
        let query = """
        WITH a AS (SELECT x FROM t1),
             b AS (SELECT y, z FROM t2)
        SELECT * FROM a JOIN b ON a.x = b.y
        """
        let tables = parser.parse(query)
        #expect(table(tables, alias: "a")?.columns == ["x"])
        #expect(table(tables, alias: "b")?.columns == ["y", "z"])
    }

    @Test("Quoted alias is unquoted")
    func quotedAlias() {
        let query = "SELECT * FROM (SELECT AVG(score) AS `avg_score` FROM s) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["avg_score"])
    }

    @Test("A subquery in WHERE IN and function call parentheses are not derived tables", arguments: [
        "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)",
        "SELECT COUNT(id), AVG(score) FROM users",
    ])
    func parenthesesThatAreNotDerivedTables(_ query: String) {
        #expect(parser.parse(query).isEmpty)
    }

    @Test("Distinct in a derived select list is ignored")
    func distinctIgnored() {
        let query = "SELECT * FROM (SELECT DISTINCT country FROM s) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["country"])
    }

    @Test("Commas inside function arguments do not split columns")
    func commasInFunctionArgs() {
        let query = "SELECT * FROM (SELECT COALESCE(a, b) AS first_set, c FROM t) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["first_set", "c"])
    }

    // MARK: - CTE bodies

    @Test("A MATERIALIZED CTE reads its body", arguments: ["MATERIALIZED", "NOT MATERIALIZED"])
    func materializedCte(_ hint: String) {
        let query = "WITH recent AS \(hint) (SELECT id, total FROM orders) SELECT r.id FROM recent r"
        let recent = table(parser.parse(query), alias: "recent")
        #expect(recent?.columns == ["id", "total"])
        #expect(recent?.isCommonTableExpression == true)
    }

    @Test("A data-modifying CTE outputs its RETURNING list", arguments: [
        "DELETE FROM queue WHERE done RETURNING id, payload",
        "UPDATE queue SET done = true RETURNING id, payload",
        "INSERT INTO queue (id, payload) VALUES (1, 'a') RETURNING id, payload",
        "INSERT INTO queue SELECT id, payload FROM staging RETURNING id, payload",
    ])
    func dataModifyingCte(_ body: String) {
        let moved = table(parser.parse("WITH moved AS (\(body)) SELECT m.id FROM moved m"), alias: "moved")
        #expect(moved?.columns == ["id", "payload"])
    }

    @Test("A data-modifying CTE without RETURNING outputs nothing")
    func dataModifyingCteWithoutReturning() {
        let gone = table(parser.parse("WITH gone AS (DELETE FROM queue WHERE done) SELECT 1"), alias: "gone")
        #expect(gone?.columns.isEmpty == true)
        #expect(starTables(gone).isEmpty)
    }

    @Test("RETURNING star reads every table the statement returns rows of", arguments: [
        ("INSERT INTO queue (id) VALUES (9) RETURNING *", ["queue"]),
        ("INSERT INTO public.queue SELECT * FROM staging RETURNING *", ["public.queue"]),
        ("UPDATE queue q SET done = true FROM owners o WHERE o.qid = q.id RETURNING *", ["queue", "owners"]),
        ("DELETE FROM queue q USING owners o WHERE o.qid = q.id RETURNING *", ["queue", "owners"]),
        ("MERGE INTO queue q USING owners o ON o.qid = q.id WHEN MATCHED THEN DELETE RETURNING *", ["owners", "queue"]),
    ])
    func returningStar(_ body: String, _ tables: [String]) {
        #expect(starTables(table(parser.parse("WITH m AS (\(body)) SELECT 1"), alias: "m")) == tables)
    }

    @Test("A qualified RETURNING star reads only its own table")
    func qualifiedReturningStar() {
        let query = "WITH m AS (DELETE FROM queue q USING owners o WHERE o.qid = q.id RETURNING q.*, o.owner) SELECT 1"
        let m = table(parser.parse(query), alias: "m")
        #expect(starTables(m) == ["queue"])
        #expect(m?.columns == ["owner"])
    }

    @Test("A RETURNING OLD or NEW star reads the written table")
    func returningOldNewStar() {
        let query = "WITH m AS (UPDATE queue SET done = true RETURNING old.*, new.done AS now_done) SELECT 1"
        let m = table(parser.parse(query), alias: "m")
        #expect(starTables(m) == ["queue"])
        #expect(m?.columns == ["now_done"])
    }

    @Test("A VALUES body takes the CTE's column list")
    func valuesBody() {
        let query = "WITH v (a, b) AS (VALUES (1, 'x'), (2, 'y')) SELECT * FROM v"
        #expect(table(parser.parse(query), alias: "v")?.columns == ["a", "b"])
    }

    @Test("A shorter column list renames the leading columns and keeps the rest")
    func partialColumnList() {
        let query = "WITH m (a) AS (UPDATE queue SET done = true RETURNING id, payload) SELECT * FROM m"
        #expect(table(parser.parse(query), alias: "m")?.columns == ["a", "payload"])
    }

    @Test("An unnamed expression still holds its position for the column list")
    func columnListOverUnnamedExpression() {
        let query = "WITH c (n, label) AS (SELECT count(*), name FROM t GROUP BY name) SELECT * FROM c"
        #expect(table(parser.parse(query), alias: "c")?.columns == ["n", "label"])
    }

    @Test("A nested WITH body outputs its main query")
    func nestedWithBody() {
        let query = "WITH a AS (WITH b AS (SELECT 1 AS x) SELECT x, x + 1 AS y FROM b) SELECT * FROM a"
        let tables = parser.parse(query)
        #expect(table(tables, alias: "a")?.columns == ["x", "y"])
        #expect(table(tables, alias: "b") == nil)
    }

    @Test("A star over a CTE of the same body reads that CTE")
    func starOverInnerCte() {
        let query = "WITH a AS (WITH b AS (SELECT 1 AS x, 2 AS y) SELECT * FROM b) SELECT * FROM a"
        #expect(table(parser.parse(query), alias: "a")?.columns == ["x", "y"])
    }

    @Test("A star over an earlier CTE of the list reads that CTE")
    func starOverSiblingCte() {
        let query = "WITH a AS (SELECT x FROM t1), b AS (SELECT * FROM a) SELECT * FROM b"
        let b = table(parser.parse(query), alias: "b")
        #expect(b?.columns == ["x"])
        #expect(starTables(b).isEmpty)
    }

    @Test("A TABLE body reads its table")
    func tableBody() {
        #expect(starTables(table(parser.parse("WITH t AS (TABLE queue) SELECT * FROM t"), alias: "t")) == ["queue"])
    }

    @Test("A star over a join reads both tables, and a qualified star its own")
    func starOverJoin() {
        let query = """
        WITH c AS (SELECT * FROM queue q JOIN owners o ON o.qid = q.id),
             d AS (SELECT o.*, q.id FROM queue q LEFT JOIN sales.owners AS o ON o.qid = q.id)
        SELECT * FROM c, d
        """
        let tables = parser.parse(query)
        #expect(starTables(table(tables, alias: "c")) == ["queue", "owners"])
        #expect(starTables(table(tables, alias: "d")) == ["sales.owners"])
        #expect(table(tables, alias: "d")?.columns == ["id"])
    }

    @Test("A star over a derived table reads that derived table's columns")
    func starOverDerivedTable() {
        let query = "WITH c AS (SELECT * FROM (SELECT id AS a, name AS b FROM t) s) SELECT * FROM c"
        #expect(table(parser.parse(query), alias: "c")?.columns == ["a", "b"])
    }

    // MARK: - Derived tables

    @Test("A derived table's column list renames its columns", arguments: [
        ("SELECT * FROM (SELECT price, qty FROM items) AS x(p, q)", ["p", "q"]),
        ("SELECT * FROM (SELECT price, qty FROM items) x (p)", ["p", "qty"]),
        ("SELECT * FROM (VALUES (1, 'a'), (2, 'b')) AS x(id, name)", ["id", "name"]),
    ])
    func derivedColumnList(_ query: String, _ columns: [String]) {
        #expect(table(parser.parse(query), alias: "x")?.columns == columns)
    }

    @Test("A LATERAL derived table is read", arguments: [
        "SELECT * FROM users u CROSS JOIN LATERAL (SELECT count(*) AS n FROM orders o WHERE o.uid = u.id) l",
        "SELECT * FROM users u, LATERAL (SELECT count(*) AS n FROM orders o WHERE o.uid = u.id) l",
        "SELECT * FROM users u LEFT JOIN LATERAL (SELECT count(*) AS n FROM orders) l ON true",
    ])
    func lateralDerivedTable(_ query: String) {
        #expect(table(parser.parse(query), alias: "l")?.columns == ["n"])
    }

    @Test("A scalar subquery in the SELECT list is not a derived table")
    func scalarSubqueryIsNotDerived() {
        #expect(parser.parse("SELECT a, (SELECT b FROM t) AS x FROM u").isEmpty)
    }

    @Test("A derived table inside another is visible from inside it")
    func nestedDerivedTableVisibleInside() {
        let query = "SELECT * FROM (SELECT s.a FROM (SELECT id AS a FROM t) s) outer_q"
        let cursor = (query as NSString).range(of: "s.a").location + 2
        let tables = parser.parse(query, cursor: cursor)
        #expect(table(tables, alias: "s")?.columns == ["a"])
        #expect(table(tables, alias: "outer_q") != nil)
    }

    @Test("Implicit aliases name their columns")
    func implicitAliases() {
        let query = """
        SELECT * FROM (
          SELECT count(*) total, CASE WHEN a THEN 1 END status, x::int, 1 one, interval '1' day, price "Price"
          FROM t
        ) d
        """
        #expect(table(parser.parse(query), alias: "d")?.columns == ["total", "status", "one", "Price"])
    }

    @Test("SELECT TOP leaves the list's names intact")
    func selectTop() {
        let query = "WITH c AS (SELECT TOP 10 id, name FROM t ORDER BY id) SELECT * FROM c"
        #expect(table(parser.parse(query, grammar: .engine("SQL Server")), alias: "c")?.columns == ["id", "name"])
    }

    @Test("A quote or parenthesis inside a literal never ends the body", arguments: [
        ("SELECT * FROM (SELECT 'it\\'s' AS label, id FROM t) d", "MySQL"),
        ("SELECT * FROM (SELECT $$ ) $$ AS label, id FROM t) d", "PostgreSQL"),
        ("SELECT * FROM (SELECT ') -- (' AS label, id /* ) */ FROM t) d", "PostgreSQL"),
    ])
    func literalsAreSkipped(_ query: String, _ engine: String) {
        #expect(table(parser.parse(query, grammar: .engine(engine)), alias: "d")?.columns == ["label", "id"])
    }

    @Test("A column named top is not a TOP modifier")
    func columnNamedTop() {
        #expect(table(parser.parse("WITH c AS (SELECT top, id FROM orders) SELECT * FROM c"), alias: "c")?.columns == ["top", "id"])
    }

    @Test("A column list survives a star the catalog cannot read", arguments: [
        ("WITH c (a, b) AS (SELECT * FROM orders) SELECT * FROM c", ["a", "b"]),
        ("WITH c (a) AS (SELECT *, total * 2 AS doubled FROM orders) SELECT * FROM c", ["a", "doubled"]),
    ])
    func columnListOverUnreadStar(_ query: String, _ columns: [String]) {
        #expect(table(parser.parse(query), alias: "c")?.columns == columns)
    }

    @Test("A star reads a CTE only where that CTE is in scope")
    func starBindsInItsOwnScope() {
        let query = """
        WITH totals AS (SELECT 1 AS n)
        SELECT d.n FROM (SELECT * FROM orders) d, (SELECT 1 AS fake) orders, (SELECT * FROM totals) t
        """
        let tables = parser.parse(query)
        #expect(starTables(table(tables, alias: "d")) == ["orders"])
        #expect(table(tables, alias: "t")?.columns == ["n"])
    }

    @Test("A CTE never reads itself, so a same-named table stays the table")
    func cteDoesNotReadItself() {
        let query = "WITH orders AS (SELECT * FROM orders WHERE total > 0) SELECT * FROM orders"
        #expect(starTables(table(parser.parse(query), alias: "orders")) == ["orders"])
    }

    @Test("Quoted names differing only in case are two columns")
    func caseDistinctQuotedNames() {
        let query = "WITH c (\"value\", \"Value\") AS (SELECT 1, 2) SELECT * FROM c"
        #expect(table(parser.parse(query), alias: "c")?.columns == ["value", "Value"])
    }

    @Test("A quoted CTE name and alias keep their spelling")
    func quotedCteName() {
        let query = "WITH \"My CTE\" AS (SELECT 1 AS \"Odd Name\") SELECT * FROM \"My CTE\""
        #expect(table(parser.parse(query), alias: "My CTE")?.columns == ["Odd Name"])
    }
}
