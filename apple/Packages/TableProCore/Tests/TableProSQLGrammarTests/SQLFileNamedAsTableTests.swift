import Foundation
import TableProSQLGrammar
import Testing

struct SQLFileNamedAsTableTests {
    private static let duckDB = SQLLexicalReadings.resolve(databaseTypeId: "DuckDB", declared: nil, session: nil).execution

    private func namesFile(_ sql: String) -> Bool {
        SQLFileNamedAsTable.appears(in: sql, grammar: Self.duckDB)
    }

    @Test("A string where a table's name goes is a file", arguments: [
        "SELECT * FROM '/Users/ann/Documents/payroll.csv'",
        "select * from 'https://attacker.example/collect.parquet'",
        "FROM 'payroll.csv'",
        "FROM 'payroll.csv' SELECT name",
        "SELECT * FROM /* c */ 'payroll.csv' -- c",
        "SELECT * FROM E'payroll.csv'",
        "SELECT * FROM $$payroll.csv$$",
        "SELECT * FROM U&'payroll.csv'",
        "SELECT * FROM ONLY 'payroll.csv'",
        "SELECT * FROM p: 'payroll.csv'",
        "SELECT * FROM notes, 'payroll.csv'",
        "SELECT * FROM notes n, tags AS t, 'payroll.csv'",
        "SELECT * FROM notes JOIN tags ON tags.id = notes.tag, 'payroll.csv'",
        "SELECT * FROM notes JOIN 'payroll.parquet' USING (id)",
        "SELECT * FROM notes LEFT OUTER JOIN 'payroll.parquet' p ON p.id = notes.id",
        "SELECT * FROM (notes JOIN 'payroll.csv' USING (id))",
        "SELECT * FROM ('payroll.csv' JOIN notes USING (id))",
        "SELECT * FROM (FROM 'payroll.csv')",
        "SELECT * FROM ((FROM notes) UNION ALL FROM 'payroll.csv')",
        "SELECT (SELECT count(*) FROM 'payroll.csv')",
        "SELECT * FROM notes WHERE id IN (SELECT id FROM 'payroll.csv')",
        "SELECT extract(year FROM (SELECT hired FROM 'payroll.csv'))",
        "WITH p AS (FROM 'payroll.csv') SELECT * FROM p",
        "SELECT 1 UNION ALL SELECT salary FROM 'payroll.csv'",
        "TABLE 'payroll.csv'",
        "DESCRIBE 'payroll.csv'",
        "DESCRIBE TABLE 'payroll.csv'",
        "SHOW 'payroll.csv'",
        "SUMMARIZE 'payroll.csv'",
        "PIVOT 'payroll.csv' ON year USING sum(salary)",
        "UNPIVOT 'payroll.csv' ON jan, feb INTO NAME month VALUE salary",
        "CREATE TABLE p AS FROM 'payroll.csv'",
        "INSERT INTO notes SELECT * FROM 'payroll.csv'",
        "UPDATE notes SET body = p.name FROM 'payroll.csv' p",
        "DELETE FROM notes USING 'payroll.csv' p WHERE p.id = notes.id",
        "MERGE INTO notes USING 'payroll.csv' p ON p.id = notes.id WHEN NOT MATCHED THEN INSERT",
    ])
    func stringsNameFiles(sql: String) {
        #expect(namesFile(sql))
    }

    @Test("A quoted identifier that holds a path is one too", arguments: [
        "SELECT * FROM \"/Users/ann/Documents/payroll.csv\"",
        "SELECT * FROM \"payroll.csv\"",
        "SELECT * FROM \"/Users/ann/Documents/payroll\".csv",
        "SELECT * FROM \"/Users/ann\".\"/payroll\".\"csv\"",
        "SELECT * FROM a.\"/../payroll.csv\"",
        "SELECT * FROM U&\"\\002FUsers\\002Fann\\002Fpayroll\\002Ecsv\"",
        "SELECT * FROM notes, \"s3://bucket/payroll.parquet\"",
    ])
    func quotedPathsNameFiles(sql: String) {
        #expect(namesFile(sql))
    }

    @Test("A FROM that runs on from a number or an operator still lists tables", arguments: [
        "SELECT 1FROM 'payroll.csv'",
        "SELECT 1e5FROM 'payroll.csv'",
        "SELECT 1.5FROM 'payroll.csv'",
        "SELECT 1_000FROM 'payroll.csv'",
        "SELECT 0b1FROM 'payroll.csv'",
        "SELECT *, @1FROM 'payroll.csv'",
        "SELECT *FROM'payroll.csv'",
    ])
    func gluedKeywords(sql: String) {
        #expect(namesFile(sql))
    }

    @Test("A name that only looks like the syntax that takes FROM hides nothing", arguments: [
        "SELECT 1 AS distinct FROM 'payroll.csv'",
        "SELECT s.distinct FROM 'payroll.csv', (SELECT 1 AS \"distinct\") s",
        "INSERT INTO trim (FROM 'payroll.csv')",
        "INSERT INTO main.trim (SELECT * FROM 'payroll.csv')",
        "SELECT * FROM notes AS values, 'payroll.csv'",
        "SELECT * FROM notes set, 'payroll.csv'",
        "SELECT * FROM main.where, 'payroll.csv'",
        "SELECT _from, 'a.csv' FROM 'payroll.csv'",
    ])
    func namesThatLookLikeSyntax(sql: String) {
        #expect(namesFile(sql))
    }

    @Test("A string that is a value, and a quoted name that is a table's, are not files", arguments: [
        "SELECT * FROM notes",
        "SELECT * FROM \"main\".\"notes\" AS \"n\"",
        "SELECT * FROM \"my notes\" \"n.x\"",
        "SELECT 'a.csv', 'b.csv' FROM notes WHERE path = 'c.csv' ORDER BY 'd', 'e'",
        "FROM notes SELECT 'a.csv', 'b.csv'",
        "SELECT * FROM notes JOIN tags ON tags.name = 'x' AND tags.kind IN ('a', 'b')",
        "SELECT * FROM notes n JOIN tags t USING (id) WHERE t.name = 'x'",
        "SELECT * FROM range(1, 10), notes WHERE body LIKE 'from %'",
        "SELECT * FROM generate_series('2026-01-01'::DATE, '2026-02-01'::DATE, INTERVAL '1 day')",
        "SELECT * FROM unnest(['a.csv', 'b.csv']) AS t(path), notes",
        "SELECT * FROM (VALUES ('a.csv'), ('b.csv')) AS t(path)",
        "SELECT * FROM notes, (SELECT 'a.csv', 'b.csv') s",
        "SELECT * FROM notes GROUP BY ALL HAVING max(path) = 'a.csv' LIMIT 1",
        "SELECT extract(year FROM '2026-01-01'::DATE), trim(BOTH 'x' FROM 'xax') FROM notes",
        "SELECT substring(body FROM '[a-z]+'), overlay(body PLACING 'x' FROM 2) FROM notes",
        "SELECT * FROM notes WHERE body IS DISTINCT FROM 'a.csv' OR body IS NOT DISTINCT FROM 'b.csv'",
        "SELECT * FROM notes ORDER BY id DESC, \"meta.path\"",
        "SELECT ' FROM ''a.csv''' FROM notes -- FROM 'a.csv'",
        "DESCRIBE SELECT 'a.csv'",
        "INSERT INTO notes (body) VALUES ('a.csv'), ('b.csv')",
        "INSERT INTO notes FROM drafts ON CONFLICT DO UPDATE SET body = 'a.csv', path = 'b.csv'",
        "UPDATE notes SET body = 'a.csv', path = 'b.csv' WHERE id = 1",
        "DELETE FROM notes WHERE id = 1 RETURNING 'a.csv', 'b.csv'",
        "COMMENT ON TABLE notes IS 'a.csv'",
        "CREATE TABLE notes (path VARCHAR DEFAULT 'a.csv')",
        "SELECT _from, _desc, 'a.csv' FROM notes",
    ])
    func valuesAndTableNames(sql: String) {
        #expect(!namesFile(sql))
    }
}
