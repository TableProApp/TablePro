import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct SQLContextAnalyzerJoinScopeTests {
    private let analyzer = SQLContextAnalyzer()

    // `|` marks the cursor.
    private func scope(_ marked: String, grammar: SQLLexicalGrammar = .ansi) -> SQLJoinScope? {
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        return analyzer.analyze(query: text, cursorPosition: marker.location, grammar: grammar).joinScope
    }

    private func names(_ marked: String, grammar: SQLLexicalGrammar = .ansi) -> [String]? {
        guard let scope = scope(marked, grammar: grammar) else { return nil }
        return [scope.joined.identifier] + scope.earlier.map(\.identifier)
    }

    @Test("Right after a join's ON, the joined table and the earlier ones, nearest first", arguments: [
        ("SELECT * FROM orders o JOIN customers c ON |", ["c", "o"]),
        ("SELECT * FROM orders o JOIN customers c ON cu|", ["c", "o"]),
        ("SELECT * FROM orders JOIN customers ON |", ["customers", "orders"]),
        ("SELECT * FROM orders o LEFT OUTER JOIN customers AS c ON |", ["c", "o"]),
        ("SELECT * FROM customers c JOIN orders o ON o.customer_id = c.id JOIN payments p ON |", ["p", "o", "c"]),
        ("SELECT * FROM a JOIN b USING (id) JOIN c ON |", ["c", "b", "a"]),
        ("SELECT * FROM a JOIN b ON a.x IS DISTINCT FROM b.x JOIN c ON |", ["c", "b", "a"]),
        ("SELECT * FROM a STRAIGHT_JOIN b ON |", ["b", "a"]),
        ("UPDATE a JOIN b ON | SET a.x = 1", ["b", "a"]),
        ("DELETE FROM t USING a JOIN b ON |", ["b", "a"]),
        ("UPDATE t SET x = 1 FROM a JOIN b ON |", ["b", "a"]),
    ])
    func joinScope(_ marked: String, _ expected: [String]) {
        #expect(names(marked) == expected)
    }

    @Test("A table joined after the cursor is not in scope")
    func laterJoinIsOutOfScope() {
        #expect(names("SELECT * FROM orders o JOIN customers c ON | JOIN payments p ON p.order_id = o.id") == ["c", "o"])
    }

    @Test("Only the tables since the last comma may be named, as the server reads the ON")
    func commaEndsTheScope() {
        #expect(names("SELECT * FROM orders o, customers c JOIN payments p ON |") == ["p", "c"])
    }

    @Test("A subquery reads its own FROM list")
    func subquery() {
        #expect(names("SELECT * FROM x WHERE id IN (SELECT 1 FROM orders o JOIN customers c ON |)") == ["c", "o"])
        #expect(names("WITH r AS (SELECT * FROM orders o JOIN customers c ON |) SELECT * FROM r") == ["c", "o"])
    }

    @Test("Inside a join group the ON names the group's own tables")
    func joinGroup() {
        #expect(names("SELECT * FROM a JOIN (b JOIN c ON |) ON a.id = b.id") == ["c", "b"])
        #expect(names("SELECT * FROM (a JOIN b ON a.id = b.id) JOIN c ON |") == ["c", "b", "a"])
    }

    @Test("A table hint between the table and its ON is skipped", arguments: [
        ("SELECT * FROM a WITH (NOLOCK) JOIN b WITH (NOLOCK) ON |", "SQL Server"),
        ("SELECT * FROM a JOIN b USE INDEX (ix_b) ON |", "MySQL"),
    ])
    func tableHint(_ marked: String, _ engine: String) {
        #expect(names(marked, grammar: .engine(engine)) == ["b", "a"])
    }

    @Test("A schema and a quoted name are kept")
    func schemaAndQuotes() throws {
        let found = try #require(scope("SELECT * FROM sales.orders \"O\" JOIN \"Customers\" ON |", grammar: .engine("PostgreSQL")))
        #expect(found.joined.tableName == "Customers")
        #expect(found.joined.alias == nil)
        #expect(found.joined.isIdentifierQuoted)
        #expect(found.earlier.first?.tableName == "orders")
        #expect(found.earlier.first?.schema == "sales")
        #expect(found.earlier.first?.alias == "O")
        #expect(found.earlier.first?.isIdentifierQuoted == true)
    }

    @Test("No scope for an ON that belongs to no join, or once the condition has started", arguments: [
        "CREATE INDEX idx ON |",
        "CREATE UNIQUE INDEX idx ON |",
        "GRANT SELECT ON |",
        "CREATE TRIGGER trg AFTER INSERT ON |",
        "CREATE TRIGGER trg AFTER UPDATE ON |",
        "MERGE INTO orders o USING customers c ON |",
        "SELECT * FROM orders o ON |",
        "SELECT * FROM orders o, customers c ON |",
        "SELECT * FROM orders o JOIN ON |",
        "SELECT * FROM orders o JOIN customers c ON o.|",
        "SELECT * FROM orders o JOIN customers c ON \"|",
        "SELECT * FROM orders o JOIN customers c ON o.customer_id = |",
        "SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id |",
        "SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id AND |",
        "SELECT * FROM orders o JOIN customers c ON|",
        "SELECT * FROM orders o CROSS APPLY f(o.id) x ON |",
    ])
    func noScope(_ marked: String) {
        #expect(scope(marked) == nil)
    }

    @Test("A derived table or a CTE has no keys, on either side", arguments: [
        "SELECT * FROM orders o JOIN (SELECT * FROM customers) c ON |",
        "SELECT * FROM (SELECT * FROM orders) o JOIN customers c ON |",
        "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent r JOIN customers c ON |",
        "WITH customers AS (SELECT 1 AS id) SELECT * FROM orders o JOIN customers c ON |",
        "SELECT * FROM orders o JOIN generate_series(1, 3) g ON |",
    ])
    func derivedSides(_ marked: String) {
        #expect(scope(marked) == nil)
    }

    @Test("A derived table before a stored one leaves the stored ones in scope")
    func derivedEarlierTable() {
        #expect(names("SELECT * FROM customers c JOIN (SELECT * FROM x) d ON d.id = c.id JOIN orders o ON |") == ["o", "c"])
    }
}
