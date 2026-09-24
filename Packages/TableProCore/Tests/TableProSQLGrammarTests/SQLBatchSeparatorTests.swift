import Foundation
import TableProSQLGrammar
import Testing

@Suite("SQL batch separator lines")
struct SQLBatchSeparatorTests {
    private static let sqlServer = SQLLexicalReadings.resolve(
        databaseTypeId: "SQL Server",
        declared: nil,
        session: nil
    ).execution

    private static let mySQL = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil).execution

    private static let postgreSQL = SQLLexicalReadings.resolve(
        databaseTypeId: "PostgreSQL",
        declared: nil,
        session: nil
    ).execution

    private func separators(_ text: String) -> [SQLBatchSeparator] {
        SQLStatementScanner.batchSeparators(in: text, grammar: Self.sqlServer)
    }

    private func statements(_ text: String, _ grammar: SQLLexicalGrammar = sqlServer) -> [String] {
        SQLStatementScanner.executableStatements(in: text, grammar: grammar).map(\.sql)
    }

    private func executableText(_ text: String) -> String {
        SQLStatementScanner.executableText(of: text, grammar: Self.sqlServer)
    }

    private func separatorText(_ text: String) -> [String] {
        separators(text).map { (text as NSString).substring(with: $0.range) }
    }

    @Test("SQL Server scripts are split at GO lines, and no other engine's are")
    func onlySQLServerHasTheFact() {
        #expect(Self.sqlServer.contains(.batchSeparatorLines))
        #expect(!Self.mySQL.contains(.batchSeparatorLines))
        #expect(!Self.postgreSQL.contains(.batchSeparatorLines))
    }

    @Test("A GO line ends the statement before it and runs nothing itself")
    func goLineEndsTheStatement() {
        let text = "SELECT 1\nGO\nDROP TABLE t"
        #expect(statements(text) == ["SELECT 1", "DROP TABLE t"])
        #expect(separators(text) == [SQLBatchSeparator(range: NSRange(location: 9, length: 2), repeatCount: 1)])
    }

    @Test("The statement ranges point at their own text, never at the GO line")
    func rangesSkipTheSeparator() {
        let text = "SELECT 1;\nGO\nSELECT 2"
        let found = SQLStatementScanner.executableStatements(in: text, grammar: Self.sqlServer)
        #expect(found.map(\.range) == [NSRange(location: 0, length: 8), NSRange(location: 13, length: 8)])
    }

    @Test("GO is read case-insensitively, after spaces and tabs, with a count and a -- comment")
    func acceptedSpellings() {
        #expect(separatorText("SELECT 1\ngo\nSELECT 2") == ["go"])
        #expect(separatorText("SELECT 1\nGo\nSELECT 2") == ["Go"])
        #expect(separatorText("SELECT 1\n\t  GO\nSELECT 2") == ["GO"])
        #expect(separatorText("SELECT 1\nGO   \nSELECT 2") == ["GO   "])
        #expect(separatorText("SELECT 1\nGO -- batch one\nSELECT 2") == ["GO -- batch one"])
        #expect(separatorText("SELECT 1\nGO--glued\nSELECT 2") == ["GO--glued"])
        #expect(separatorText("SELECT 1\nGO 2 -- twice\nSELECT 2") == ["GO 2 -- twice"])
        #expect(separatorText("SELECT 1\nGO\t7\nSELECT 2") == ["GO\t7"])
    }

    @Test("GO n carries its repeat count")
    func repeatCount() {
        #expect(separators("INSERT t VALUES (1)\nGO 5").map(\.repeatCount) == [5])
        #expect(separators("INSERT t VALUES (1)\nGO 05").map(\.repeatCount) == [5])
        #expect(separators("INSERT t VALUES (1)\nGO 2147483647").map(\.repeatCount) == [2_147_483_647])
        #expect(separators("INSERT t VALUES (1)\nGO").map(\.repeatCount) == [1])
    }

    @Test(
        "A line that holds anything else is not a separator, and reaches the server as the text it is",
        arguments: [
            "GO;", "GO 0", "GO -1", "GO x", "GO 2147483648", "GO 99999999999999999999", "GOTO done", "go_table",
            "GO5", "GO /* c */", "GO 2 3", "GO 2x",
        ]
    )
    func rejectedLines(line: String) {
        let text = "SELECT 1\n\(line)\nSELECT 2"
        #expect(separators(text).isEmpty)
    }

    @Test(
        "A reader that tracked the line start reads each line as the scanner does",
        arguments: [
            "GO", "go", "GO   ", "GO -- batch one", "GO--glued", "GO 2 -- twice", "GO\t7", "GO 05", "GO 2147483647",
            "GO;", "GO 0", "GO -1", "GO x", "GO 2147483648", "GOTO done", "go_table", "GO5", "GO /* c */", "GO 2 3",
        ]
    )
    func lineStartingAtAgreesWithTheScanner(line: String) {
        let text = "SELECT 1\n\(line)\nSELECT 2"
        let lineStart = 9
        let buffer = "\(line)\nSELECT 2" as NSString
        let read = SQLBatchSeparator.line(startingAt: 0, in: buffer, length: buffer.length, grammar: Self.sqlServer)
        let scanned = separators(text).first
        #expect(read?.repeatCount == scanned?.repeatCount)
        #expect(read.map { NSRange(location: $0.range.location + lineStart, length: $0.range.length) } == scanned?.range)
    }

    @Test("The caller vouches for the line start, so text before the GO is not read")
    func lineStartingAtTrustsTheCaller() {
        let buffer = "  GO 3\nSELECT 2" as NSString
        let read = SQLBatchSeparator.line(startingAt: 2, in: buffer, length: buffer.length, grammar: Self.sqlServer)
        #expect(read == SQLBatchSeparator(range: NSRange(location: 2, length: 4), repeatCount: 3))
    }

    @Test("GO after code on the same line is not a separator")
    func goMustStartTheLine() {
        #expect(separators("SELECT 1 GO\nSELECT 2").isEmpty)
        #expect(separators("SELECT 1; GO\nSELECT 2").isEmpty)
        #expect(separators("/* note */ GO\nSELECT 2").isEmpty)
        #expect(separators("/* a\n*/GO\nSELECT 2").isEmpty)
    }

    @Test("Carriage returns end a GO line as line feeds do")
    func carriageReturns() {
        let text = "SELECT 1\r\nGO\r\nSELECT 2\rGO\rSELECT 3"
        #expect(separatorText(text) == ["GO", "GO"])
        #expect(statements(text) == ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    @Test("A GO line may end the document")
    func goAtTheEnd() {
        #expect(separatorText("SELECT 1\nGO") == ["GO"])
        #expect(separatorText("SELECT 1\nGO 3 -- last") == ["GO 3 -- last"])
        #expect(statements("SELECT 1\nGO") == ["SELECT 1"])
        #expect(separatorText("GO") == ["GO"])
        #expect(statements("GO").isEmpty)
    }

    @Test("GO inside a literal, a quoted identifier or a block comment separates nothing, across lines too")
    func goInsideNonCode() {
        let texts = [
            "SELECT 'a\nGO\nb'",
            "SELECT N'a\nGO\nb'",
            "SELECT [a\nGO\nb] FROM t",
            "SELECT \"a\nGO\nb\" FROM t",
            "/* a\nGO\n*/ SELECT 1",
            "/* outer /* inner */\nGO\nstill outer */ SELECT 1",
            "SELECT 1 -- GO\nSELECT 2",
        ]
        for text in texts {
            #expect(separators(text).isEmpty, "\(text)")
            #expect(statements(text).count == 1, "\(text)")
        }
    }

    @Test("An unterminated block comment swallows every GO line after it, as sqlcmd reads it")
    func unterminatedCommentSwallowsGo() {
        let text = "SELECT 1\n/* open\nGO\nSELECT 2\nGO"
        #expect(separators(text).isEmpty)
        #expect(statements(text) == ["SELECT 1\n/* open\nGO\nSELECT 2\nGO"])
    }

    @Test("GO lines in a row end empty batches, which hold no statement")
    func consecutiveSeparators() {
        let text = "SELECT 1\nGO\nGO\n\nGO 2\nSELECT 2\nGO"
        #expect(separators(text).count == 4)
        #expect(statements(text) == ["SELECT 1", "SELECT 2"])
    }

    /// Sent whole, a leading `GO` answers Msg 2812, "Could not find stored procedure 'GO'", and SQL Server still runs
    /// the statement after it, so a tool reported a failure for a `DROP` that had run (measured on Azure SQL Edge 15).
    @Test("A GO line before the first statement stays out of the text sent whole")
    func leadingSeparatorIsNotSent() {
        #expect(executableText("GO\nDROP TABLE dbo.stale") == "DROP TABLE dbo.stale")
        #expect(executableText("  go -- lead\n\nDROP TABLE dbo.stale;") == "DROP TABLE dbo.stale")
        #expect(executableText("GO\nGO 3\n-- keep\nSELECT 1\nGO") == "-- keep\nSELECT 1")
        #expect(executableText("SELECT 1\nGO\nSELECT 2") == "SELECT 1\nGO\nSELECT 2")
    }

    @Test("The reporter's script has no GO, so it stays five statements in one batch")
    func reporterScriptIsUnchanged() {
        let text = """
            DECLARE @sn NVARCHAR(50) = '2404GQV000066A00105';

            SELECT *
            FROM serialnew
            WHERE [S/N] = @sn;

            SELECT *
            FROM [v_wms_joined]
            WHERE [S/N] = @sn;

            SELECT *
            FROM drm_report_n
            WHERE [Serial number] = @sn;

            SELECT *
            FROM serial_existed
            WHERE sn_code = @sn;
            """
        #expect(separators(text).isEmpty)
        #expect(statements(text).count == 5)
    }

    @Test("A script TablePro writes for SQL Server divides at its GO lines and sends none of them")
    func writtenScriptDividesAtGo() {
        let text = "DROP PROCEDURE p;\nGO\nCREATE PROCEDURE p AS SET NOCOUNT ON; SELECT 1;\nGO"
        #expect(separators(text).count == 2)
        let found = statements(text)
        #expect(found.first == "DROP PROCEDURE p")
        #expect(found.allSatisfy { !$0.uppercased().contains("GO") })
    }

    @Test("A GO line ends a routine body left open, so the next batch is not swallowed into it")
    func goClosesAnOpenBody() {
        let text = "CREATE PROCEDURE p AS BEGIN SELECT 1;\nGO\nSELECT 2"
        #expect(statements(text).last == "SELECT 2")
        #expect(statements(text).count == 2)
    }

    @Test("A statement with no semicolon before its GO line ends on the line before", arguments: [
        "SET ANSI_NULLS ON\nGO\nCREATE TABLE [dbo].[x]([a] [int] NULL)\nGO",
    ])
    func semicolonFreeScript(text: String) {
        #expect(statements(text) == ["SET ANSI_NULLS ON", "CREATE TABLE [dbo].[x]([a] [int] NULL)"])
    }

    @Test("An engine without batches reads a GO line as part of the statement", arguments: [mySQL, postgreSQL])
    func otherEnginesKeepGo(grammar: SQLLexicalGrammar) {
        let text = "SELECT 1\nGO\nDROP TABLE t"
        #expect(SQLStatementScanner.batchSeparators(in: text, grammar: grammar).isEmpty)
        #expect(statements(text, grammar) == [text])
    }

    @Test("Navigation never lands on a GO line")
    func navigationSkipsTheSeparator() {
        let text = "SELECT 1\nGO\nSELECT 2"
        let navigable = SQLStatementScanner.navigableStatements(in: text, grammar: Self.sqlServer)
        #expect(navigable.map(\.contentRange) == [NSRange(location: 0, length: 8), NSRange(location: 12, length: 8)])
        #expect(SQLStatementScanner.statementStart(after: 3, in: text, grammar: Self.sqlServer) == 12)
        #expect(SQLStatementScanner.statementStart(after: 10, in: text, grammar: Self.sqlServer) == 12)
        #expect(SQLStatementScanner.statementStart(before: 15, in: text, grammar: Self.sqlServer) == 12)
        #expect(SQLStatementScanner.statementStart(before: 12, in: text, grammar: Self.sqlServer) == 0)
        #expect(SQLStatementScanner.statementSelectionEnd(after: 3, in: text, grammar: Self.sqlServer) == 12)
    }

    @Test("A caret on a GO line stands for the last statement of the batch the line ends")
    func caretOnTheSeparator() {
        let text = "SELECT 1;\nSELECT 2\nGO\nSELECT 3"
        let onGo = SQLStatementScanner.locatedStatementAtCursor(in: text, cursorPosition: 20, grammar: Self.sqlServer)
        #expect(SQLStatementScanner.executableStatement(from: onGo)?.sql == "SELECT 2")
        #expect(SQLStatementScanner.statementAtCursor(in: text, cursorPosition: 21, grammar: Self.sqlServer) == "SELECT 2")
        #expect(SQLStatementScanner.statementAtCursor(in: text, cursorPosition: 26, grammar: Self.sqlServer) == "SELECT 3")
    }

    @Test("A caret on a GO line that ends an empty batch runs nothing, not the batch before it")
    func caretOnAnEmptyBatchSeparator() {
        let text = "SELECT 1\nGO\nGO\nSELECT 2"
        let onSecond = SQLStatementScanner.locatedStatementAtCursor(in: text, cursorPosition: 13, grammar: Self.sqlServer)
        #expect(!onSecond.hasContent)
        #expect(SQLStatementScanner.executableStatements(in: onSecond.sql, grammar: Self.sqlServer).isEmpty)
        #expect(SQLStatementScanner.statementAtCursor(in: text, cursorPosition: 10, grammar: Self.sqlServer) == "SELECT 1")
    }

    @Test("A gate reading an unknown engine sees the GO split only when the text can hold one")
    func relevanceFollowsTheText() {
        let unknown = SQLLexicalReadings.resolve(databaseTypeId: "Nonesuch", declared: nil, session: nil)
        #expect(unknown.distinct(for: "SELECT 1\nGO\nDROP TABLE t").contains { $0.contains(.batchSeparatorLines) })
        #expect(!unknown.distinct(for: "SELECT 1; DELETE FROM t").contains { $0.contains(.batchSeparatorLines) })
    }
}
