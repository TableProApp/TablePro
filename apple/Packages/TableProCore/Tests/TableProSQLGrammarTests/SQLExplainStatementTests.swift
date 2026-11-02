import Foundation
import TableProSQLGrammar
import Testing

struct SQLExplainStatementTests {
    private static let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil)
        .execution

    private func read(_ sql: String) -> SQLExplainStatement.Reading? {
        SQLExplainStatement.read(sql, grammar: Self.postgreSQL)?.reading
    }

    private func explained(_ sql: String) -> (statement: String, runs: Bool)? {
        guard case .explains(let start, let runs) = read(sql) else { return nil }
        return ((sql as NSString).substring(from: start), runs)
    }

    @Test("A parenthesised statement is the statement, not an option list")
    func parenthesisedStatement() {
        let sql = "EXPLAIN ANALYZE (WITH g AS (DELETE FROM t RETURNING *) SELECT 1)"
        #expect(explained(sql)?.statement == "(WITH g AS (DELETE FROM t RETURNING *) SELECT 1)")
        #expect(explained(sql)?.runs == true)
    }

    @Test("A quoted, unknown or ANALYZE option may run the statement", arguments: [
        "EXPLAIN (\"analyze\") DELETE FROM t",
        "EXPLAIN (VERBOSE, U&\"analyze\") DELETE FROM t",
        "EXPLAIN (ANALYSE) DELETE FROM t",
        "EXPLAIN frobnicate DELETE FROM t",
        "DESC ANALYZE DELETE FROM t",
        "ANALYZE SELECT 1",
    ])
    func optionThatMayRun(sql: String) {
        #expect(explained(sql)?.runs == true)
    }

    @Test("ANALYZE turned off with FALSE, OFF or 0 only plans", arguments: [
        ("EXPLAIN (ANALYZE FALSE) DELETE FROM t", false),
        ("EXPLAIN (analyze off, FORMAT JSON) DELETE FROM t", false),
        ("EXPLAIN (ANALYZE 0) DELETE FROM t", false),
        ("EXPLAIN (ANALYZE TRUE) DELETE FROM t", true),
        ("EXPLAIN (ANALYZE OFF, ANALYZE) DELETE FROM t", true),
        ("EXPLAIN (ANALYZE OFFSET) DELETE FROM t", true),
        ("EXPLAIN (ANALYZE 01) DELETE FROM t", true),
        ("EXPLAIN (ANALYZE 'off') DELETE FROM t", true),
    ])
    func analyzeTurnedOff(sql: String, runs: Bool) {
        #expect(explained(sql)?.runs == runs)
    }

    @Test("A planning option leaves the statement unrun, and its comments stay with it", arguments: [
        ("EXPLAIN (FORMAT \"json\", VERBOSE) DELETE FROM t", "DELETE FROM t"),
        ("EXPLAIN FORMAT /* x */ = JSON /* plan */ SELECT 1", "/* plan */ SELECT 1"),
        ("EXPLAIN QUERY PLAN -- note\nSELECT 1", "-- note\nSELECT 1"),
        ("EXPLAIN PLAN header = 1, actions = 1 SELECT 1", "SELECT 1"),
    ])
    func planningOption(sql: String, statement: String) {
        #expect(explained(sql)?.statement == statement)
        #expect(explained(sql)?.runs == false)
    }

    @Test("A name alone is described, and a text with no statement is unreadable")
    func describedAndUnreadable() {
        #expect(read("DESC orders") == .describesObject)
        #expect(read("ANALYZE TABLE orders") == .describesObject)
        #expect(read("DESC FUNCTION f(NUMBER)") == .describesObject)
        #expect(read("EXPLAIN PRAGMA query_only(1)") == .unreadable)
        #expect(read("EXPLAIN QUERY PLAN PRAGMA query_only = ON") == .unreadable)
        #expect(read("EXPLAIN") == .unreadable)
        #expect(read("SELECT 1") == nil)
    }
}

struct SQLCommonTableExpressionsTests {
    private static let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil)
        .execution

    private func parts(_ sql: String) -> (main: String, bodies: [String])? {
        guard let reading = SQLCommonTableExpressions.read(sql, grammar: Self.postgreSQL) else { return nil }
        let text = sql as NSString
        return (text.substring(from: reading.mainStatement), reading.bodies.map(text.substring(with:)))
    }

    @Test("Each body and the main statement are found")
    func bodiesAndMain() {
        let sql = "WITH RECURSIVE a(n) AS (SELECT 1), \"b\" AS NOT MATERIALIZED (DELETE FROM t RETURNING 1) REPLACE INTO x"
        #expect(parts(sql)?.main == "REPLACE INTO x")
        #expect(parts(sql)?.bodies == ["SELECT 1", "DELETE FROM t RETURNING 1"])
    }

    @Test("ClickHouse expressions, SEARCH clauses and a parenthesised query are read", arguments: [
        ("WITH 1 AS one, sum(x) AS s SELECT one", "SELECT one"),
        ("WITH t AS (SELECT 1) SEARCH DEPTH FIRST BY id SET ord SELECT * FROM t", "SELECT * FROM t"),
        ("WITH t AS (SELECT 1) (SELECT 1) UNION (SELECT 2)", "(SELECT 1) UNION (SELECT 2)"),
        ("(WITH t AS (SELECT 1) SELECT 2)", "SELECT 2)"),
    ])
    func otherShapes(sql: String, main: String) {
        #expect(parts(sql)?.main == main)
    }

    @Test("A list this reader does not know is unreadable", arguments: [
        "WITH",
        "WITH x AS (SELECT 1)",
        "WITH p AS PROCEDURE () RETURNS INT AS $$ SELECT 1 $$ CALL p()",
        "WITH x AS (SELECT 1) , ",
        "SELECT 1",
    ])
    func unknownList(sql: String) {
        #expect(parts(sql) == nil)
    }
}

struct SQLPreparedStatementTests {
    private static let mySQL = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil).execution

    @Test("What a PREPARE stores is found as text or as a statement")
    func preparedBody() {
        let text = "PREPARE s FROM 'DROP TABLE t'"
        #expect(SQLPreparedStatement.body(in: text, grammar: Self.mySQL) == .text(at: 15))
        let statement = "PREPARE q (int) AS DELETE FROM t"
        #expect(SQLPreparedStatement.body(in: statement, grammar: Self.mySQL) == .statement(at: 19))
        #expect(SQLPreparedStatement.body(in: "PREPARE TRANSACTION 'x'", grammar: Self.mySQL) == nil)
        #expect(SQLPreparedStatement.body(in: "SELECT 1", grammar: Self.mySQL) == nil)
    }
}
