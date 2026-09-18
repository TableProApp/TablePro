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
        #expect(statement.query == "DELETE FROM [t] WHERE [payload] = @p1")
        #expect(statement.declarations == "@p1 VARBINARY(MAX)")
        #expect(statement.assignments == "@p1 = 0xDEADBEEF")
    }

    @Test("An empty binary is still binary")
    func emptyBinaryIsStillBinary() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?", parameters: [.bytes(Data())]
        )
        #expect(statement.declarations == "@p1 VARBINARY(MAX)")
        #expect(statement.assignments == "@p1 = 0x")
    }

    @Test("Text is an nvarchar literal and null stays null")
    func textAndNullKeepTheirTypes() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?, ?", parameters: [.text("O'Brien"), .null]
        )
        #expect(statement.declarations == "@p1 NVARCHAR(MAX), @p2 NVARCHAR(MAX)")
        #expect(statement.assignments == "@p1 = N'O''Brien', @p2 = NULL")
    }

    /// Non-Latin text in a parameter is the same problem the literals have: a plain `'…'` is a
    /// `varchar` and a non-Unicode collation turns it into question marks.
    @Test("Text parameters carry the N prefix")
    func textParametersAreNvarcharLiterals() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?", parameters: [.text("日本語")]
        )
        #expect(statement.assignments == "@p1 = N'日本語'")
    }

    @Test("Each parameter is declared as the type its own value is")
    func typesArePerParameter() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT ?, ?, ?",
            parameters: [.text("a"), .bytes(Data([0x01])), .null]
        )
        #expect(statement.declarations == "@p1 NVARCHAR(MAX), @p2 VARBINARY(MAX), @p3 NVARCHAR(MAX)")
        #expect(statement.assignments == "@p1 = N'a', @p2 = 0x01, @p3 = NULL")
    }

    /// A `?` inside a literal or a quoted identifier is data. Reading one as a placeholder shifts
    /// every parameter after it by one.
    @Test("A question mark inside a literal or an identifier is not a placeholder")
    func questionMarksInsideLiteralsAreData() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT '?', [we?ird], ? FROM [t] WHERE [a] = ?",
            parameters: [.text("x"), .text("y")]
        )
        #expect(statement.query == "SELECT '?', [we?ird], @p1 FROM [t] WHERE [a] = @p2")
        #expect(statement.declarations == "@p1 NVARCHAR(MAX), @p2 NVARCHAR(MAX)")
    }

    @Test("A doubled closing bracket does not end an identifier")
    func doubledBracketsStayInsideTheIdentifier() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT [a]]?b], ? FROM [t]", parameters: [.text("x")]
        )
        #expect(statement.query == "SELECT [a]]?b], @p1 FROM [t]")
    }

    @Test("A doubled quote inside a literal does not end it")
    func doubledQuotesStayInsideTheLiteral() {
        let statement = MSSQLParameterBatch.spExecuteSql(
            query: "SELECT 'it''s ?', ?", parameters: [.text("x")]
        )
        #expect(statement.query == "SELECT 'it''s ?', @p1")
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
        #expect(statement.query == "SELECT @p1, ?")
        #expect(statement.declarations == "@p1 NVARCHAR(MAX)")
    }
}
