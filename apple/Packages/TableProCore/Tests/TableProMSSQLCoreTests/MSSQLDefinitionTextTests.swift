import Foundation
import TableProMSSQLCore
import Testing

struct MSSQLDefinitionTextTests {
    // INFORMATION_SCHEMA.COLUMNS returns the first 4,000 characters of a longer default, its literal left open.
    @Test("A default cut inside its literal is not written")
    func truncatedDefaultIsRefused() {
        #expect(MSSQLDefinitionText.expression("('" + String(repeating: "A", count: 3_998)) == nil)
    }

    @Test("A default as the catalog stores it is written as it is", arguments: ["((0))", "(getdate())", "(N'it''s')"])
    func catalogDefaultIsWritten(text: String) {
        #expect(MSSQLDefinitionText.expression(text) == text)
    }

    @Test("A default typed without its parentheses is written inside a pair")
    func typedDefaultIsParenthesized() {
        #expect(MSSQLDefinitionText.expression("0") == "(0)")
        #expect(MSSQLDefinitionText.expression("getdate()") == "(getdate())")
        #expect(MSSQLDefinitionText.expression("N'a;b'") == "(N'a;b')")
    }

    @Test("Text that reaches past its parentheses is not written", arguments: [
        "(0)) DROP TABLE t; --",
        "0) DROP TABLE t (",
        "0; DROP TABLE t",
        "0 -- x",
        "0 /* x */",
        "(0)\nGO\nDROP TABLE t",
        "",
        "   ",
    ])
    func escapingTextIsRefused(text: String) {
        #expect(MSSQLDefinitionText.expression(text) == nil)
    }

    @Test("A column type is a name and at most one argument group", arguments: [
        "int", "INT", "nvarchar(max)", "decimal(18,2)", "datetime2(7)", "dbo.Money", "[dbo].[Mo]]ney]",
        "xml(CONTENT dbo.schemas)", "nvarchar (50)", "dbo.Währung", "[dbo].[Währung]", "dbo.通貨", "dbo.𠀀",
    ])
    func columnTypeIsAccepted(type: String) {
        #expect(MSSQLDefinitionText.isColumnType(type))
    }

    // Measured on SQL Server 2022: each is whitespace, and the words after `int` ran as a second statement.
    @Test("A non-ASCII space ends the type, so a word after it is refused", arguments: [
        "\u{0085}", "\u{1680}", "\u{200B}", "\u{2028}", "\u{2029}",
    ])
    func nonASCIISpaceEndsTheType(space: String) {
        #expect(!MSSQLDefinitionText.isColumnType(["int", "DROP", "TABLE", "x"].joined(separator: space)))
    }

    @Test("A documented ISO synonym takes its second word", arguments: [
        "double precision", "DOUBLE  PRECISION", "character varying(255)", "Char Varying (10)", "national character",
        "national char(10)", "national character varying(max)", "NATIONAL CHAR VARYING(50)", "national text",
        "binary varying(max)",
    ])
    func multiWordSynonymIsAccepted(type: String) {
        #expect(MSSQLDefinitionText.isColumnType(type))
    }

    @Test("A synonym with anything past it, or another second word, is refused", arguments: [
        "double precision DROP TABLE t",
        "national character varying(50) DROP TABLE t",
        "national DROP TABLE t",
        "dbo.double precision",
        "double /* x */ precision",
        "double precısıon",
    ])
    func multiWordTextIsRefused(type: String) {
        #expect(!MSSQLDefinitionText.isColumnType(type))
    }

    // T-SQL starts a statement at a bare keyword, so a second word after the type would run as one.
    @Test("Type text with anything past its name and arguments is refused", arguments: [
        "int DROP TABLE t",
        "nvarchar(50) DROP TABLE t",
        "int); DROP TABLE t; --",
        "int, x int",
        "int -- x",
        "nvarchar(50",
        "[a",
        "",
    ])
    func columnTypeIsRefused(type: String) {
        #expect(!MSSQLDefinitionText.isColumnType(type))
    }

    @Test("An identity is a whole-number seed and increment")
    func identitySpecification() {
        #expect(MSSQLDefinitionText.isIdentitySpecification("1,1"))
        #expect(MSSQLDefinitionText.isIdentitySpecification("-5,10"))
        #expect(MSSQLDefinitionText.isIdentitySpecification("1000000000000,+2"))
        #expect(!MSSQLDefinitionText.isIdentitySpecification("1,1) NOT NULL, [x] int"))
        #expect(!MSSQLDefinitionText.isIdentitySpecification("1"))
        #expect(!MSSQLDefinitionText.isIdentitySpecification("1,"))
        #expect(!MSSQLDefinitionText.isIdentitySpecification("\u{0661},1"))
    }

    @Test("A collation is a collation name")
    func collationName() {
        #expect(MSSQLDefinitionText.isCollationName("Latin1_General_100_CI_AS_SC_UTF8"))
        #expect(!MSSQLDefinitionText.isCollationName("Latin1_General_CI_AS NOT NULL"))
        #expect(!MSSQLDefinitionText.isCollationName(""))
    }

    @Test("Only the four referential actions are written")
    func referentialActions() {
        #expect(MSSQLDefinitionText.referentialAction("CASCADE") == "CASCADE")
        #expect(MSSQLDefinitionText.referentialAction("set null") == "SET NULL")
        #expect(MSSQLDefinitionText.referentialAction("CASCADE; DROP TABLE t") == nil)
        #expect(MSSQLDefinitionText.referentialAction("RESTRICT") == "NO ACTION")
    }

    @Test("An index kind is one of the two rowstore kinds")
    func indexKinds() {
        #expect(MSSQLDefinitionText.indexKind("clustered") == "CLUSTERED")
        #expect(MSSQLDefinitionText.indexKind("CLUSTERED; DROP TABLE t") == nil)
        #expect(MSSQLDefinitionText.indexKind(nil) == nil)
    }
}
