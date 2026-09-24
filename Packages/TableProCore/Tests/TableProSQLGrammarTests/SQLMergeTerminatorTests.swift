import Foundation
import TableProSQLGrammar
import Testing

/// SQL Server fails a whole batch whose `MERGE` has no `;` with Msg 10713. Every case was measured on Azure SQL Edge
/// 15.0, and `scripts/check-mssql-merge-terminator.sh` measures them again.
@Suite("SQL MERGE terminator")
struct SQLMergeTerminatorTests {
    private static let sqlServer = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        .execution

    private static let merge = """
        MERGE dbo.t AS t USING dbo.s AS s ON t.id = s.id WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)
        """

    /// A `MERGE` that begins a statement, the way the server reads one.
    private static let mergeStatements: [String] = [
        Self.merge + ";",
        "merge dbo.t AS t USING dbo.s AS s ON t.id = s.id WHEN MATCHED THEN DELETE;",
        "WITH src AS (SELECT id, v FROM dbo.s) " + Self.merge + ";",
        "IF 1 = 1 " + Self.merge + ";",
        "IF 1 = 0 SELECT 1 ELSE " + Self.merge + ";",
        "WHILE 1 = 0 " + Self.merge + ";",
        "DECLARE @d INT = 1 " + Self.merge + ";",
        "BEGIN TRAN " + Self.merge + ";",
        "SELECT 1 AS a " + Self.merge + ";",
        "SELECT 1" + Self.merge + ";",
        "SELECT 1." + Self.merge + ";",
        "CREATE PROCEDURE dbo.p AS " + Self.merge + ";",
        "CREATE OR ALTER TRIGGER dbo.trg ON dbo.s AFTER INSERT AS " + Self.merge + ";",
        Self.merge + " OUTPUT $action, inserted.id OPTION (LOOP JOIN);",
        "MERGE TOP (1) INTO [dbo].[t] WITH (HOLDLOCK) AS t USING (VALUES (1, 10)) AS s (id, v) ON t.id = s.id "
            + "WHEN MATCHED THEN UPDATE SET v = s.v WHEN NOT MATCHED BY SOURCE THEN DELETE;",
        "MERGE #staging AS t USING dbo.s AS s ON t.id = s.id WHEN MATCHED THEN DELETE;",
        "MERGE @changes AS t USING dbo.s AS s ON t.id = s.id WHEN MATCHED THEN DELETE;",
        Self.merge + " -- loaded nightly\n;",
        "TRUNCATE TABLE dbo.\u{6CE8}\u{6587}\n" + Self.merge + ";",
        "SELECT id, qualit\u{00E9} FROM dbo.produits ORDER BY qualit\u{00E9}\n" + Self.merge + ";",
        "SELECT 1 AS caf\u{00E9} -- note\n" + Self.merge + ";",
        "SELECT 1 AS x$\n" + Self.merge + ";",
        "SELECT COUNT(*) FROM dbo.\u{9867}\u{5BA2} /* c */ " + Self.merge + ";",
        "MERGE range AS t USING dbo.s AS s ON t.id = s.id WHEN MATCHED THEN DELETE;",
        "MERGE Range AS t USING dbo.s AS s ON t.id = s.id WHEN MATCHED THEN UPDATE SET v = s.v;",
    ]

    /// A `MERGE` inside parentheses, a hint or a name, none of which needs a `;`.
    private static let otherStatements: [String] = [
        "SELECT s.id FROM dbo.s AS s INNER MERGE JOIN dbo.t AS t ON s.id = t.id;",
        "SELECT id FROM dbo.s OPTION (MERGE JOIN, MERGE UNION);",
        "INSERT INTO dbo.log (act, id) SELECT act, id FROM (" + Self.merge
            + " OUTPUT $action, inserted.id) AS c (act, id);",
        "DECLARE @merge INT = 1 SELECT @merge;",
        "SELECT a FROM #merge;",
        "SELECT 1 AS x$merge;",
        "SELECT 1 AS \u{00E9}merge;",
        "SELECT 1 AS \u{6CE8}\u{6587}MERGE;",
        "SELECT merge_date FROM dbo.t;",
        "SELECT [merge] FROM dbo.t;",
        "SELECT 'MERGE' AS a;",
        "SELECT 1 /* MERGE */;",
        "CREATE PROCEDURE dbo.p AS BEGIN " + Self.merge + "; END;",
    ]

    private func sent(_ sql: String, _ grammar: SQLLexicalGrammar = sqlServer) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    @Test("SQL Server is the only curated engine whose MERGE keeps its ;")
    func onlySQLServerKeepsTheMergeTerminator() {
        let keeping = SQLLexicalProfile.curatedDatabaseTypeIds.filter { typeId in
            SQLLexicalProfile.curated(forDatabaseTypeId: typeId)?.readings.contains {
                $0.contains(.terminatedMergeStatements)
            } == true
        }
        #expect(keeping == ["SQL Server"])
    }

    @Test("An engine nobody declared strips the ; after a MERGE, and one that declares the rule keeps it")
    func unknownEnginesOnlyWhenDeclared() {
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy { !$0.contains(.terminatedMergeStatements) })
        let unknown = SQLLexicalReadings.resolve(databaseTypeId: "Nonesuch", declared: nil, session: nil)
        #expect(unknown.all.allSatisfy { sent(Self.merge + ";", $0) == [Self.merge] })
        let declared = SQLLexicalReadings.resolve(
            databaseTypeId: "Nonesuch",
            declared: [.bracketQuotedIdentifiers, .terminatedMergeStatements],
            session: nil
        )
        #expect(sent(Self.merge + ";", declared.execution) == [Self.merge + ";"])
    }

    @Test("Other engines still strip the ; after a MERGE", arguments: ["PostgreSQL", "Oracle", "Snowflake", "DuckDB"])
    func otherEnginesStripIt(typeId: String) {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        #expect(sent(Self.merge + ";", grammar) == [Self.merge])
    }

    @Test("A MERGE the server runs as a statement keeps the ; that ends it", arguments: mergeStatements)
    func mergeKeepsItsTerminator(sql: String) {
        #expect(sent(sql) == [sql])
    }

    @Test("A ; that ends anything but a MERGE statement is still a separator", arguments: otherStatements)
    func otherStatementsLoseTheSeparator(sql: String) {
        #expect(sent(sql) == [String(sql.dropLast())])
    }

    /// `RANGE` is not reserved, so `MERGE range` is a statement on a table of that name, and the `;` this keeps is one
    /// the server accepts after any statement.
    @Test("The ; after ALTER PARTITION FUNCTION ... MERGE RANGE is kept, and the server runs it")
    func mergeRangeKeepsItsTerminator() {
        let sql = "ALTER PARTITION FUNCTION pf () MERGE RANGE (2);"

        #expect(sent(sql) == [sql])
    }

    @Test("A reader that drops every ; tracks only the grammars whose statements can own one")
    func statementsCanOwnTerminator() {
        let owning = SQLLexicalProfile.curatedDatabaseTypeIds.filter { typeId in
            let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
            return SQLStatementBoundaries.statementsCanOwnTerminator(in: grammar)
        }
        #expect(Set(owning) == ["SQL Server", "Oracle"])
    }

    @Test("In a script only the MERGE keeps its ;")
    func scriptKeepsOnlyTheMergeTerminator() {
        let script = "DECLARE @d DATE = GETDATE();\nUPDATE dbo.s SET v = 1;\n\(Self.merge);\nSELECT 1;"

        #expect(sent(script) == [
            "DECLARE @d DATE = GETDATE()", "UPDATE dbo.s SET v = 1", Self.merge + ";", "SELECT 1",
        ])
        let located = SQLStatementScanner.locatedStatements(in: script, grammar: Self.sqlServer)
        #expect(located.map(\.terminator) == [.separator, .separator, .partOfStatement, .separator])
    }

    @Test("A script that ends with a MERGE is sent whole with the ; the MERGE needs")
    func scriptEndingInMergeKeepsItsLastTerminator() {
        let script = "DECLARE @d DATE = GETDATE();\nUPDATE dbo.s SET v = 1;\n\(Self.merge);"

        #expect(SQLStatementScanner.executableText(of: script + "\n\n", grammar: Self.sqlServer) == script)
    }

    @Test("The statement's range covers the ;, so text cut at the range keeps it")
    func rangeCoversTheTerminator() throws {
        let text = "SELECT 1;\n\(Self.merge);\n"
        let last = try #require(SQLStatementScanner.executableStatements(in: text, grammar: Self.sqlServer).last)

        #expect((text as NSString).substring(with: last.range) == Self.merge + ";")
    }

    @Test("The statement at the cursor keeps a MERGE's ;")
    func statementAtCursorKeepsIt() {
        let text = "SELECT 1;\n\(Self.merge);\nSELECT 2;"

        #expect(SQLStatementScanner.statementAtCursor(in: text, cursorPosition: 15, grammar: Self.sqlServer)
            == Self.merge + ";")
    }

    @Test("A GO line ends the MERGE it follows, so the next batch's ; is a separator again")
    func batchSeparatorResetsIt() {
        let text = "\(Self.merge);\nGO\nSELECT 1;"

        #expect(sent(text) == [Self.merge + ";", "SELECT 1"])
    }
}
