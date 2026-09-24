import Foundation
import TableProSQLGrammar
import Testing

/// What each case stands for was measured on Azure SQL Edge 15.0, and `scripts/check-mssql-unterminated-statements.sh`
/// measures it again.
@Suite("SQL unterminated statements")
struct SQLUnterminatedStatementsTests {
    private static let sqlServer = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        .execution

    private func inner(_ sql: String, _ grammar: SQLLexicalGrammar = sqlServer) -> [String] {
        SQLUnterminatedStatements.runnable(in: sql, grammar: grammar).dropFirst().map(StatementBlank.trimming)
    }

    private func begins(_ keyword: String, in sql: String) -> Bool {
        inner(sql).contains { $0.uppercased().hasPrefix(keyword) }
    }

    @Test("SQL Server is the only curated engine whose statements need no terminator")
    func onlySQLServerNeedsNoTerminator() {
        let unterminated = SQLLexicalProfile.curatedDatabaseTypeIds.filter { typeId in
            SQLLexicalProfile.curated(forDatabaseTypeId: typeId)?.readings.contains {
                $0.contains(.unterminatedStatements)
            } == true
        }
        #expect(unterminated == ["SQL Server"])
    }

    @Test("An engine nobody declared is not read as T-SQL, and one that declares it is")
    func unknownEnginesOnlyWhenDeclared() {
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy { !$0.contains(.unterminatedStatements) })
        let declared = SQLLexicalReadings.resolve(
            databaseTypeId: "Nonesuch",
            declared: [.bracketQuotedIdentifiers, .unterminatedStatements],
            session: nil
        )
        #expect(declared.execution.contains(.unterminatedStatements))
    }

    @Test("The statement itself always comes first")
    func statementComesFirst() {
        let sql = "SELECT 1\nDROP TABLE t"
        #expect(SQLUnterminatedStatements.runnable(in: sql, grammar: Self.sqlServer).first == sql)
    }

    @Test("An engine that needs a terminator gets its statement back alone")
    func terminatedEnginesAreUntouched() {
        let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil).execution
        #expect(SQLUnterminatedStatements.runnable(in: "SELECT 1 DROP TABLE t", grammar: postgreSQL)
            == ["SELECT 1 DROP TABLE t"])
    }

    @Test("Statements written one after another without a terminator are each returned", arguments: [
        ("SELECT 1\nDROP TABLE t", ["SELECT 1", "DROP TABLE t"]),
        ("SELECT 1 DELETE FROM t", ["SELECT 1", "DELETE FROM t"]),
        ("PRINT 'x' UPDATE t SET c = 1", ["PRINT 'x'", "UPDATE t SET c = 1"]),
        ("SET NOCOUNT ON DELETE FROM t", ["SET NOCOUNT ON", "DELETE FROM t"]),
        ("SELECT 1 TRUNCATE TABLE t", ["SELECT 1", "TRUNCATE TABLE t"]),
        ("SELECT 1 EXEC('DELETE FROM t')", ["SELECT 1", "EXEC('DELETE FROM t')"]),
        ("WAITFOR DELAY '00:00:00' DELETE FROM t", ["WAITFOR DELAY '00:00:00'", "DELETE FROM t"]),
        ("SELECT DB_NAME() USE master", ["SELECT DB_NAME()", "USE master"]),
        ("SELECT 1 END CONVERSATION @h", ["SELECT 1", "END CONVERSATION @h"]),
        ("DELETE FROM t SELECT 1 WHERE 1 = 1", ["DELETE FROM t", "SELECT 1 WHERE 1 = 1"]),
        ("CREATE TYPE dbo.t FROM int DROP TABLE x", ["CREATE TYPE dbo.t FROM int", "DROP TABLE x"]),
        ("SELECT 1 LINENO 5 DELETE FROM t", ["SELECT 1", "LINENO 5", "DELETE FROM t"]),
    ])
    func juxtaposedStatements(sql: String, expected: [String]) {
        #expect(inner(sql) == expected)
    }

    @Test("A quoted name stands between the words around it, so the statement it follows still begins", arguments: [
        ("SELECT 1\nUPDATE [t] SET c = 9", ["SELECT 1", "UPDATE [t] SET c = 9"]),
        ("SELECT 1\nUPDATE \"t\" SET c = 9", ["SELECT 1", "UPDATE \"t\" SET c = 9"]),
        ("SELECT 1\nUPDATE [t]\nSET c = 9", ["SELECT 1", "UPDATE [t]\nSET c = 9"]),
        ("PRINT 1\nUPDATE [t] SET c = 9", ["PRINT 1", "UPDATE [t] SET c = 9"]),
        ("PRINT 1\nSELECT [a], [b] INTO x FROM t", ["PRINT 1", "SELECT [a], [b] INTO x FROM t"]),
        ("PRINT 1\nSELECT \"a\", b INTO x FROM t", ["PRINT 1", "SELECT \"a\", b INTO x FROM t"]),
    ])
    func quotedNameBetweenWords(sql: String, expected: [String]) {
        #expect(inner(sql) == expected)
    }

    @Test("A keyword glued to a number begins a statement, as the server lexes it", arguments: [
        "SELECT 1DELETE FROM t", "SELECT 1.DELETE FROM t", "SELECT 1e1DELETE FROM t", "SELECT 1eDELETE FROM t",
        "SELECT 1.5e+2DELETE FROM t", "SELECT 1E+DELETE FROM t", "SELECT $1DELETE FROM t", "SELECT €1DELETE FROM t",
        "SELECT .5DELETE FROM t", "SELECT N'a'DELETE FROM t", "SELECT 1 AS \"a\"DELETE FROM t",
        "SELECT 1/**/DELETE FROM t", "SELECT (1)DELETE FROM t", "SELECT 1\u{00A0}DELETE FROM t",
        "SELECT 1\u{3000}DELETE FROM t", "SELECT 1\u{200B}DELETE FROM t", "SELECT 1\u{2028}DELETE FROM t",
        "SELECT 1\u{0B}DELETE FROM t", "SELECT 1\u{01}DELETE FROM t",
    ])
    func keywordGluedToALiteral(sql: String) {
        #expect(begins("DELETE", in: sql))
    }

    @Test("A keyword the server reads as part of a name or a literal begins nothing", arguments: [
        "SELECT 0xDELETE FROM t", "SELECT 0x1DELETE FROM t", "SELECT 1xDELETE FROM t", "SELECT 1_DELETE FROM t",
        "SELECT 1 a$DELETE FROM t", "SELECT 1 a#DELETE FROM t", "SELECT 1 a@DELETE FROM t",
        "SELECT 1 éDELETE FROM t", "DECLARE @DELETE int = 1 SELECT @DELETE", "SELECT * FROM #DELETE",
        "SELECT 1 ＤＥＬＥＴＥ FROM t", "SELECT 1EXEC('DELETE FROM t')",
        "SELECT 'DELETE FROM t'", "SELECT 1 -- DELETE FROM t", "SELECT 1 /* DELETE FROM t */",
        "SELECT [DELETE] FROM t", "SELECT \"DELETE\" FROM t", "SELECT deleted_at, last_delete FROM t",
    ])
    func keywordInsideANameOrLiteral(sql: String) {
        #expect(!begins("DELETE", in: sql))
        #expect(!begins("EXEC", in: sql))
    }

    @Test("A keyword is spelled in ASCII, so a letter Unicode cases into one begins nothing", arguments: [
        "SELECT 1 \u{0131}nsert INTO t VALUES (9)", "SELECT 1 \u{0130}NSERT INTO t VALUES (9)",
        "SELECT 1 \u{0131}n\u{017F}ert INTO t VALUES (9)", "SELECT 1 CHEC\u{212A}POINT",
    ])
    func keywordsAreASCII(sql: String) {
        #expect(inner(sql).allSatisfy { $0.uppercased().hasPrefix("SELECT") })
    }

    @Test("An UPDATE keeps its own SET clause, and a SET after it begins a statement")
    func updateKeepsItsSetClause() {
        #expect(inner("UPDATE t SET c = 1 WHERE id = 2") == ["UPDATE t SET c = 1 WHERE id = 2"])
        #expect(inner("UPDATE TOP (5) t WITH (ROWLOCK) SET c = 1 SET NOCOUNT OFF")
            == ["UPDATE TOP (5) t WITH (ROWLOCK) SET c = 1", "SET NOCOUNT OFF"])
        #expect(inner("UPDATE STATISTICS t SET NOCOUNT ON") == ["UPDATE STATISTICS t", "SET NOCOUNT ON"])
        #expect(inner("MERGE t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET c = s.c;")
            == ["MERGE t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET c = s.c"])
        #expect(inner("UPDATE [t] SET [c] = 1 SET NOCOUNT OFF") == ["UPDATE [t] SET [c] = 1", "SET NOCOUNT OFF"])
        #expect(inner("MERGE [t] USING [s] ON [t].[id] = [s].[id] WHEN MATCHED THEN UPDATE SET [c] = [s].[c];")
            == ["MERGE [t] USING [s] ON [t].[id] = [s].[id] WHEN MATCHED THEN UPDATE SET [c] = [s].[c]"])
    }

    @Test("A word that only continues a read begins nothing", arguments: [
        "SELECT * FROM t OPTION (USE HINT('DISABLE_OPTIMIZER_ROWGOAL'))",
        "SELECT * FROM t OPTION (USE PLAN N'<xml/>')",
        "SELECT a.id FROM t a INNER MERGE JOIN s b ON a.id = b.id OPTION (MERGE JOIN, MERGE UNION)",
        "SELECT id FROM t ORDER BY id OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY",
        "SELECT CASE WHEN a = 1 THEN 'x' ELSE 'y' END FROM t",
        "SELECT * FROM t WITH (NOLOCK) WHERE id IN (SELECT id FROM s)",
        "SELECT 1 disable",
        "SELECT 1 receive WHERE 1 = 1",
    ])
    func readsStayReads(sql: String) {
        #expect(inner(sql).allSatisfy { $0.uppercased().hasPrefix("SELECT") })
    }

    @Test("An unreserved keyword cannot begin a statement without a terminator", arguments: [
        "SELECT 1 DISABLE TRIGGER ALL ON t", "SELECT 1 RECEIVE * FROM q", "SELECT 1 THROW 50000, 'x', 1",
        "SELECT 1 SEND ON CONVERSATION @h",
    ])
    func unreservedKeywordsBeginNothing(sql: String) {
        #expect(inner(sql) == [sql])
    }

    @Test("A permission, a foreign key action and a MERGE action begin nothing", arguments: [
        ("GRANT SELECT, INSERT, UPDATE, DELETE ON t TO u", "GRANT"),
        ("DENY EXECUTE, ALTER TO u", "DENY"),
        ("REVOKE DELETE ON t FROM u", "REVOKE"),
        (
            "ALTER TABLE t ADD CONSTRAINT fk FOREIGN KEY (a) REFERENCES p (id) ON DELETE CASCADE ON UPDATE NO ACTION",
            "ALTER"
        ),
        ("CREATE TABLE t (a int REFERENCES p (id) ON DELETE SET NULL ON UPDATE SET DEFAULT)", "CREATE"),
        ("GRANT SELECT, UPDATE ON [t] TO [u]", "GRANT"),
        ("ALTER TABLE [t] ADD FOREIGN KEY ([a]) REFERENCES [p] ([id]) ON DELETE CASCADE ON UPDATE SET NULL", "ALTER"),
        (
            "MERGE t USING s ON t.id = s.id WHEN MATCHED THEN DELETE WHEN NOT MATCHED THEN INSERT (id) VALUES (s.id);",
            "MERGE"
        ),
    ])
    func continuationsBeginNothing(sql: String, keyword: String) {
        let found = inner(sql)
        #expect(found.first?.uppercased().hasPrefix(keyword) == true)
        #expect(!found.contains { $0.uppercased().hasPrefix("DELETE") })
        #expect(!found.contains { $0.uppercased().hasPrefix("INSERT") })
    }

    @Test("A procedure, function or trigger runs nothing written after its header", arguments: [
        "CREATE PROCEDURE dbo.p AS SELECT 1 DROP TABLE t",
        "CREATE OR ALTER PROCEDURE dbo.p AS BEGIN SELECT 1 END DROP TABLE t",
        "ALTER PROC dbo.p AS SELECT 1 DROP TABLE t",
        "CREATE FUNCTION dbo.f() RETURNS int AS BEGIN RETURN 1 END DROP TABLE t",
        "CREATE OR ALTER TRIGGER dbo.trg ON dbo.t AFTER DELETE AS BEGIN DELETE FROM x END",
        "/* header */ CREATE PROCEDURE dbo.p AS DELETE FROM t",
    ])
    func routineBodiesRunNothing(sql: String) {
        #expect(SQLUnterminatedStatements.runnable(in: sql, grammar: Self.sqlServer) == [sql])
    }

    @Test("A statement inside parentheses ends at the parenthesis that closes it, and comes on its own")
    func nestedStatementEndsAtItsParenthesis() {
        let sql = "INSERT INTO log SELECT id FROM (DELETE FROM t OUTPUT deleted.id) AS d"
        #expect(inner(sql) == ["INSERT INTO log", "SELECT id FROM () AS d", "DELETE FROM t OUTPUT deleted.id"])
    }

    @Test("A subquery does not end the statement around it, so its WHERE stays with it")
    func subqueryKeepsTheOuterWhere() {
        let sql = "DELETE t FROM t JOIN (SELECT id FROM s) AS x ON x.id = t.id WHERE x.id > 1"
        #expect(inner(sql) == ["DELETE t FROM t JOIN () AS x ON x.id = t.id WHERE x.id > 1", "SELECT id FROM s"])
    }

    @Test("A WHERE nested in a subquery is not the DELETE's own")
    func nestedWhereStaysNested() {
        let sql = "DELETE t FROM t JOIN (SELECT id FROM s WHERE s.x = 1) AS q ON q.id = t.id"
        #expect(inner(sql) == ["DELETE t FROM t JOIN () AS q ON q.id = t.id", "SELECT id FROM s WHERE s.x = 1"])
    }

    @Test("Deeply nested statements are each read once")
    func deepNestingIsLinear() {
        let depth = 20_000
        let sql = "SELECT " + String(repeating: "(SELECT ", count: depth) + "1" + String(repeating: ")", count: depth)
        let found = SQLUnterminatedStatements.runnable(in: sql, grammar: Self.sqlServer)
        #expect(found.count == depth + 2)
        #expect(found.dropFirst().map { ($0 as NSString).length }.reduce(0, +) == (sql as NSString).length)
    }

    @Test("A statement ends at a terminator inside the text the scanner kept whole")
    func terminatorEndsAStatement() {
        let sql = "DECLARE @x int BEGIN DELETE FROM t; SELECT 1 WHERE 1 = 1; END"
        #expect(inner(sql).contains("DELETE FROM t"))
    }

    @Test("A long script without terminators is read in one pass")
    func longScriptIsLinear() {
        let sql = Array(repeating: "INSERT INTO t (a, b) VALUES (1, (SELECT 2))", count: 20_000).joined(separator: "\n")
        let found = inner(sql)
        #expect(found.count == 40_000)
        #expect(Array(found.prefix(2)) == ["INSERT INTO t (a, b) VALUES (1, ())", "SELECT 2"])
    }
}
