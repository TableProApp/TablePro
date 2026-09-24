import Foundation
import Testing

@testable import TableProMSSQLCore

@Suite("MSSQL parameter batch")
struct MSSQLParameterBatchTests {
    /// Every parameter used to be declared `NVARCHAR(MAX)` and assigned from the value's text, and
    /// a binary value has none: it was sent as `NULL`, so a row matched on a `VARBINARY` column
    /// found nothing and the update or delete reported success having touched no row.
    @Test("A binary parameter is declared and sent as binary")
    func binaryParameterKeepsItsBytes() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "DELETE FROM [t] WHERE [payload] = ?",
            parameters: [.bytes(Data([0xDE, 0xAD, 0xBE, 0xEF]))]
        )
        #expect(statement.query == "DELETE FROM [t] WHERE [payload] = @__tablepro_p1")
        #expect(statement.declarations == "@__tablepro_p1 VARBINARY(MAX)")
        #expect(statement.assignments == "@__tablepro_p1 = 0xDEADBEEF")
    }

    @Test("An empty binary is still binary")
    func emptyBinaryIsStillBinary() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?", parameters: [.bytes(Data())]
        )
        #expect(statement.declarations == "@__tablepro_p1 VARBINARY(MAX)")
        #expect(statement.assignments == "@__tablepro_p1 = 0x")
    }

    @Test("Text is an nvarchar literal and null stays null")
    func textAndNullKeepTheirTypes() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?, ?", parameters: [.text("O'Brien"), .null]
        )
        #expect(statement.declarations == "@__tablepro_p1 NVARCHAR(MAX), @__tablepro_p2 NVARCHAR(MAX)")
        #expect(statement.assignments == "@__tablepro_p1 = N'O''Brien', @__tablepro_p2 = NULL")
    }

    /// Non-Latin text in a parameter is the same problem the literals have: a plain `'…'` is a
    /// `varchar` and a non-Unicode collation turns it into question marks.
    @Test("Text parameters carry the N prefix")
    func textParametersAreNvarcharLiterals() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?", parameters: [.text("日本語")]
        )
        #expect(statement.assignments == "@__tablepro_p1 = N'日本語'")
    }

    @Test("Each parameter is declared as the type its own value is")
    func typesArePerParameter() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?, ?, ?",
            parameters: [.text("a"), .bytes(Data([0x01])), .null]
        )
        #expect(statement.declarations == "@__tablepro_p1 NVARCHAR(MAX), @__tablepro_p2 VARBINARY(MAX), @__tablepro_p3 NVARCHAR(MAX)")
        #expect(statement.assignments == "@__tablepro_p1 = N'a', @__tablepro_p2 = 0x01, @__tablepro_p3 = NULL")
    }

    /// A `?` inside a literal or a quoted identifier is data. Reading one as a placeholder shifts
    /// every parameter after it by one.
    @Test("A question mark inside a literal or an identifier is not a placeholder")
    func questionMarksInsideLiteralsAreData() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT '?', [we?ird], ? FROM [t] WHERE [a] = ?",
            parameters: [.text("x"), .text("y")]
        )
        #expect(statement.query == "SELECT '?', [we?ird], @__tablepro_p1 FROM [t] WHERE [a] = @__tablepro_p2")
        #expect(statement.declarations == "@__tablepro_p1 NVARCHAR(MAX), @__tablepro_p2 NVARCHAR(MAX)")
    }

    @Test("A doubled closing bracket does not end an identifier")
    func doubledBracketsStayInsideTheIdentifier() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT [a]]?b], ? FROM [t]", parameters: [.text("x")]
        )
        #expect(statement.query == "SELECT [a]]?b], @__tablepro_p1 FROM [t]")
    }

    @Test("A doubled quote inside a literal does not end it")
    func doubledQuotesStayInsideTheLiteral() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT 'it''s ?', ?", parameters: [.text("x")]
        )
        #expect(statement.query == "SELECT 'it''s ?', @__tablepro_p1")
    }

    @Test("A query with no placeholder declares nothing")
    func noPlaceholdersDeclaresNothing() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT 1", parameters: [.text("unused")]
        )
        #expect(statement.isEmpty)
        #expect(statement.query == "SELECT 1")
    }

    @Test("More placeholders than parameters leaves the extra ones alone")
    func extraPlaceholdersAreLeftAlone() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?, ?", parameters: [.text("a")]
        )
        #expect(statement.query == "SELECT @__tablepro_p1, ?")
        #expect(statement.declarations == "@__tablepro_p1 NVARCHAR(MAX)")
    }

    /// `sp_executesql` declares its parameters in the scope of the text it runs, so a generated name the text also
    /// declares fails the whole batch with Msg 134.
    @Test("Generated names cannot collide with a variable the batch declares")
    func generatedNamesAvoidUserVariables() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "DECLARE @p1 INT = 5; SELECT @p1, ?", parameters: [.text("a")]
        )
        #expect(statement.query == "DECLARE @p1 INT = 5; SELECT @p1, @__tablepro_p1")
        #expect(statement.declarations == "@__tablepro_p1 NVARCHAR(MAX)")
    }

    @Test("An apostrophe in a line comment does not hide the placeholders after it")
    func apostropheInLineCommentIsInert() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "-- customer's orders\nSELECT * FROM [orders] WHERE [id] = ?", parameters: [.text("2")]
        )
        #expect(statement.query == "-- customer's orders\nSELECT * FROM [orders] WHERE [id] = @__tablepro_p1")
    }

    @Test("A question mark in a comment is not a placeholder")
    func questionMarkInCommentIsInert() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "-- why?\nSELECT ? /* or ? */", parameters: [.text("a"), .text("b")]
        )
        #expect(statement.query == "-- why?\nSELECT @__tablepro_p1 /* or ? */")
        #expect(statement.declarations == "@__tablepro_p1 NVARCHAR(MAX)")
    }

    @Test("A bracket or a double quote in a block comment opens nothing")
    func delimitersInBlockCommentAreInert() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "/* see [docs, say \"hi */ SELECT ?", parameters: [.text("a")]
        )
        #expect(statement.query == "/* see [docs, say \"hi */ SELECT @__tablepro_p1")
    }

    /// The app's parameter scanner ends a block comment at the first `*/` and writes a `?` for every `:name` after it,
    /// so both marks carry a value. Nesting here, as the server does, bound the second mark's value to the first.
    @Test("A block comment ends at its first closing mark, as the app's scanner reads it")
    func blockCommentEndsAtFirstClose() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "/* a /* b */ ? */ DELETE FROM t WHERE id = ?", parameters: [.text("10"), .text("20")]
        )
        #expect(statement.query == "/* a /* b */ @__tablepro_p1 */ DELETE FROM t WHERE id = @__tablepro_p2")
        #expect(statement.assignments == "@__tablepro_p1 = N'10', @__tablepro_p2 = N'20'")
    }

    /// `"\r\n"` is one `Character`, equal to neither `"\n"` nor `"\r"`.
    @Test("A line comment ends at CRLF")
    func lineCommentEndsAtCRLF() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT * FROM orders -- recent\r\nWHERE customer_id = ?", parameters: [.text("7")]
        )
        #expect(statement.query == "SELECT * FROM orders -- recent\r\nWHERE customer_id = @__tablepro_p1")
        #expect(!statement.isEmpty)
    }

    /// The app's scanner ends a line comment at a line feed and nowhere else, and it only wrote a `?` for a `:name` it
    /// read as code, so a comment here runs exactly as far.
    @Test("A line comment runs on past a line break that holds no line feed", arguments: [
        "\r", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}",
    ])
    func lineCommentRunsPastOtherBreaks(lineBreak: String) {
        let query = "SELECT 1 -- note" + lineBreak + "SELECT ?"
        let statement = MSSQLParameterBatch.spExecuteSql(query: query, parameters: [.text("a")])
        #expect(statement.query == query)
        #expect(statement.isEmpty)
    }

    @Test("Comment markers inside a literal are text")
    func commentMarkersInsideLiteralsAreText() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT '-- not a comment', ?", parameters: [.text("a")]
        )
        #expect(statement.query == "SELECT '-- not a comment', @__tablepro_p1")
    }

    /// `sp_executesql` runs its text one scope down: a `BEGIN TRAN` inside it fails with Msg 266 and a `#temp` table
    /// made inside it is gone when it returns. Declaring the values in front keeps the batch at its own scope.
    @Test("A batch binds its values in a declaration at its own head")
    func batchBindsInItsOwnScope() {
        let bound = MSSQLParameterBatch.boundBatch(
            query: "BEGIN TRAN;\nUPDATE t SET v = ? WHERE id = ?;",
            parameters: [.text("x"), .bytes(Data([0x01]))]
        )
        #expect(bound?.text == "DECLARE @__tablepro_p1 NVARCHAR(MAX) = N'x', @__tablepro_p2 VARBINARY(MAX) = 0x01; "
            + "BEGIN TRAN;\nUPDATE t SET v = @__tablepro_p1 WHERE id = @__tablepro_p2;")
        #expect(bound?.leadingLineFeeds == 0)
        #expect(bound?.prependedStatementCount == 1)
    }

    @Test("A batch with no placeholder binds nothing")
    func batchWithoutPlaceholdersBindsNothing() {
        #expect(MSSQLParameterBatch.boundBatch(query: "SELECT 1", parameters: [.text("x")]) == nil)
    }

    /// The server counts only a line feed as a new line, so a value holding them moves every line of the batch down.
    @Test("Line feeds in a declared value are given back to the reported line")
    func lineFeedsInValuesAreGivenBack() throws {
        let bound = try #require(MSSQLParameterBatch.boundBatch(
            query: "SELECT ? AS a;\nSELECT 1/0 AS b;", parameters: [.text("x\r\ny\nz")]
        ))
        #expect(bound.leadingLineFeeds == 2)
        #expect(bound.batchLine(forReportedLine: 4) == 2)
        #expect(bound.batchLine(forReportedLine: 1) == 1)
    }

    @Test("A carriage return alone is not a new line to the server")
    func carriageReturnAloneIsNotALineFeed() {
        let bound = MSSQLParameterBatch.boundBatch(query: "SELECT ?", parameters: [.text("a\rb\u{2028}c")])
        #expect(bound?.leadingLineFeeds == 0)
    }

    /// A declaration in front of these would fail with Msg 111, so they keep the `sp_executesql` call.
    @Test("A batch that must start its batch is still wrapped", arguments: [
        "CREATE PROCEDURE p AS SELECT ?",
        "create proc p as select ?",
        "ALTER FUNCTION f() RETURNS INT AS BEGIN RETURN ? END",
        "CREATE OR ALTER VIEW v AS SELECT ? AS x",
        "-- note\n/* block */ CREATE TRIGGER tr ON t AFTER INSERT AS SELECT ?",
        "CREATE SCHEMA s",
        "CREATE DEFAULT d AS ?",
        "CREATE RULE r AS @v > ?",
    ])
    func routineBatchesKeepTheCall(query: String) {
        #expect(MSSQLParameterBatch.mustStartBatch(query))
    }

    @Test("Other batches take the declaration", arguments: [
        "SELECT ?",
        "CREATE TABLE #t (v INT); INSERT INTO #t VALUES (?)",
        "ALTER TABLE t ADD c INT",
        "CREATE INDEX ix ON t (c)",
        "-- CREATE PROCEDURE p\nSELECT ?",
        "UPDATE [CREATE] SET v = ?",
    ])
    func otherBatchesTakeTheDeclaration(query: String) {
        #expect(!MSSQLParameterBatch.mustStartBatch(query))
    }

    @Test("A routine batch is sent through sp_executesql")
    func routineBatchIsSentThroughExecuteSql() {
        let bound = MSSQLParameterBatch.boundBatch(query: "CREATE VIEW v AS SELECT ? AS x", parameters: [.text("a")])
        #expect(bound?.text == "EXEC sp_executesql N'CREATE VIEW v AS SELECT @__tablepro_p1 AS x', "
            + "N'@__tablepro_p1 NVARCHAR(MAX)', @__tablepro_p1 = N'a'")
        #expect(bound?.leadingLineFeeds == 0)
        #expect(bound?.prependedStatementCount == 0)
    }

    /// A bare procedure name runs as an `EXECUTE` only as the first statement of its batch; behind a declaration the
    /// server answers Msg 102.
    @Test("A procedure called without EXEC keeps a batch of its own", arguments: [
        "sp_help ?",
        "usp_Report ?, ?",
        "dbo.usp_Report ?",
        "[dbo].[usp_Report] ?",
        "\"usp_Report\" ?",
        "usp_Report2 ?",
        "-- run it\n/* now */ sp_help ?",
    ])
    func procedureCallsWithoutExecKeepTheirBatch(query: String) {
        #expect(MSSQLParameterBatch.callsProcedureWithoutExec(query))
        #expect(MSSQLParameterBatch.needsBatchOfItsOwn(query))
        let bound = MSSQLParameterBatch.boundBatch(query: query, parameters: [.text("a"), .text("b")])
        #expect(bound?.text.hasPrefix("EXEC sp_executesql N'") == true)
        #expect(bound?.prependedStatementCount == 0)
    }

    @Test("A batch that opens with a statement keyword takes the declaration", arguments: [
        "SELECT ?",
        "select ?",
        "EXEC sp_help ?",
        ";WITH c AS (SELECT ? AS v) SELECT v FROM c",
        "(SELECT ?)",
        "BEGIN TRAN; UPDATE t SET v = ?",
        "IF ? = 1 PRINT 'one'",
        "  \n-- lead\nDECLARE @a INT = ?",
    ])
    func statementBatchesTakeTheDeclaration(query: String) {
        #expect(!MSSQLParameterBatch.needsBatchOfItsOwn(query))
        let bound = MSSQLParameterBatch.boundBatch(query: query, parameters: [.text("1")])
        #expect(bound?.text.hasPrefix("DECLARE @__tablepro_p1 NVARCHAR(MAX) = N'1'; ") == true)
    }
}
