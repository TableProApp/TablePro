import Foundation
@testable import TableProAutocomplete
import Testing

struct SQLContextAnalyzerStatementShapeTests {
    let analyzer = SQLContextAnalyzer()

    // `|` marks the cursor.
    private func context(_ marked: String) -> SQLContext {
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        return analyzer.analyze(query: text, cursorPosition: marker.location)
    }

    @Test("SET reads the UPDATE's own table, not a FROM table", arguments: [
        "UPDATE orders SET st| FROM customers c WHERE c.id = orders.customer_id",
        "WITH u AS (UPDATE orders SET st| WHERE id = 1 RETURNING *) SELECT * FROM u",
        "WITH c AS (SELECT * FROM customers) UPDATE orders o SET st| FROM c WHERE c.id = o.customer_id",
    ])
    func setTarget(_ marked: String) {
        let context = context(marked)
        #expect(context.clauseType == .set)
        #expect(context.targetTable?.tableName == "orders")
    }

    @Test("ON CONFLICT DO UPDATE SET reads the INSERT's table")
    func onConflictTarget() {
        let context = context("INSERT INTO orders (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET st|")
        #expect(context.clauseType == .set)
        #expect(context.targetTable?.tableName == "orders")
    }

    @Test("An INSERT column list reads the INSERT's table, not the SELECT's")
    func insertColumnsTarget() {
        let context = context("INSERT INTO orders (|) SELECT id, name FROM customers")
        #expect(context.clauseType == .insertColumns)
        #expect(context.targetTable?.tableName == "orders")
    }

    @Test("An INSERT column list follows a qualified or quoted table")
    func qualifiedInsertColumns() {
        let context = context("INSERT INTO sales.\"Orders\" AS o (id, |")
        #expect(context.clauseType == .insertColumns)
        #expect(context.targetTable?.tableName == "Orders")
        #expect(context.targetTable?.schema == "sales")
    }

    @Test("ORDER BY carries the SELECT list's aliases as written")
    func orderByAliases() {
        let context = context("SELECT price * qty AS line_total, name, count(*) \"Total\" FROM items ORDER BY li|")
        #expect(context.clauseType == .orderBy)
        #expect(context.outputAliases == ["line_total", "\"Total\""])
    }

    @Test("ORDER BY reads the aliases of its own query level", arguments: [
        ("WITH c AS (SELECT 1 AS inner_alias) SELECT a AS outer_alias FROM c ORDER BY |", ["outer_alias"]),
        ("SELECT * FROM (SELECT a AS inner_alias FROM t ORDER BY |) d", ["inner_alias"]),
        ("SELECT a AS first_alias FROM t UNION SELECT b AS second_alias FROM u ORDER BY |", ["first_alias"]),
    ])
    func orderByLevel(_ marked: String, _ aliases: [String]) {
        #expect(context(marked).outputAliases == aliases)
    }

    @Test("ORDER BY inside a call or WITHIN GROUP orders the input, so it carries no alias", arguments: [
        "SELECT string_agg(name, ',' ORDER BY |) AS names FROM items",
        "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY |) AS median FROM items",
    ])
    func orderByInsideCall(_ marked: String) {
        let context = context(marked)
        #expect(context.clauseType == .orderBy)
        #expect(context.outputAliases.isEmpty)
    }

    @Test("LATERAL is never read as a table")
    func lateralIsNotATable() {
        let context = context("SELECT l.| FROM users u CROSS JOIN LATERAL (SELECT 1 AS n) l, LATERAL (SELECT 2 AS m) k")
        #expect(!context.tableReferences.contains { $0.tableName.uppercased() == "LATERAL" })
        #expect(context.tableReferences.first { $0.identifier == "l" }?.derivedColumns == ["n"])
    }

    @Test("CTE names include MATERIALIZED and column-list CTEs")
    func cteNamesForEveryShape() {
        let context = context("""
        WITH a AS MATERIALIZED (SELECT 1), b (x) AS (VALUES (1)), c AS (DELETE FROM t RETURNING id) SELECT |
        """)
        #expect(context.cteNames == ["a", "b", "c"])
    }

    @Test("A RETURNING star keeps its table for the catalog")
    func returningStarProjection() {
        let context = context("WITH moved AS (DELETE FROM queue RETURNING *) SELECT m.| FROM moved m")
        let moved = context.tableReferences.first { $0.identifier == "m" }
        #expect(moved?.isDerived == true)
        #expect(moved?.derivedProjection?.tables.map { $0.name } == ["queue"])
    }

    @Test("A schema-qualified table is never a CTE of the same name")
    func qualifiedTableIsNotCte() {
        let context = context("WITH orders AS (SELECT 1 AS n) SELECT o.| FROM public.orders o")
        #expect(context.tableReferences.first { $0.identifier == "o" }?.isDerived == false)
    }
}
