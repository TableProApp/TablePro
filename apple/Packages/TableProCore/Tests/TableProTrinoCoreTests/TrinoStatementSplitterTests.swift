import Foundation
import TableProSQLGrammar
import TableProTrinoCore
import Testing

struct TrinoStatementSplitterTests {
    @Test("Statements around quotes and comments are cut at each semicolon", arguments: [
        ("SELECT 1; SELECT 2", ["SELECT 1", "SELECT 2"]),
        ("SELECT ';' AS s; SELECT \"a;b\" FROM t", ["SELECT ';' AS s", "SELECT \"a;b\" FROM t"]),
        ("SELECT 1 -- ;\n; /* ; */ SELECT 2;", ["SELECT 1 -- ;", "/* ; */ SELECT 2"]),
        ("-- only a comment\n;SELECT 1", ["SELECT 1"]),
    ])
    func cutsPlainStatements(sql: String, expected: [String]) {
        #expect(TrinoStatementSplitter.split(sql) == expected)
    }

    @Test("A routine body keeps its semicolons")
    func routineBodyStaysWhole() {
        let sql = "CREATE FUNCTION f(x bigint) RETURNS bigint BEGIN DECLARE y bigint; RETURN x; END"
        #expect(TrinoStatementSplitter.split(sql) == [sql])
    }

    // The gates count these with the same scanner; main's splitter sent the DROP as a request of its own.
    @Test("The cut is the one the gates count and the app runs", arguments: ["Trino", "Presto"], [
        "CREATE TABLE notes (begin bigint); DROP TABLE orders",
        "CREATE VIEW v AS SELECT begin FROM t; DROP TABLE orders",
        "CREATE FUNCTION memory.default.plus_one(begin bigint) RETURNS bigint RETURN begin + 1; DROP TABLE orders",
        "SELECT 'a'';b' /* ; */; -- x\nSELECT 2",
    ])
    func matchesTheExecutionReading(typeId: String, sql: String) {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        #expect(TrinoStatementSplitter.split(sql) == SQLStatementScanner.allStatements(in: sql, grammar: grammar))
    }
}
