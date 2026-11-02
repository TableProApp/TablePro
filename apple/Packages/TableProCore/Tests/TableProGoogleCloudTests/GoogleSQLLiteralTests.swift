import TableProGoogleCloud
import Testing

struct GoogleSQLLiteralTests {
    // `'''` opens a triple-quoted literal in GoogleSQL, and `''` is no escape there.
    @Test("A value starting with two quotes stays one literal, never a triple-quoted opener")
    func leadingQuotesStayOneLiteral() {
        let quoted = GoogleSQLLiteral.quotedString("'' OR TRUE --")
        #expect(quoted == #"'\'\' OR TRUE --'"#)
        #expect(!quoted.hasPrefix("'''"))
    }

    @Test("A quote or backslash a combining mark follows is still escaped")
    func literalSeesQuoteBeforeCombiningMark() {
        let quoted = GoogleSQLLiteral.quotedString("a'\u{301}b\\\u{301}")
        #expect(Array(quoted.unicodeScalars) == Array("'a\\'\u{301}b\\\\\u{301}'".unicodeScalars))
    }

    @Test("A backquote or backslash in a name is escaped with a backslash")
    func identifierEscapesBackquote() {
        let quoted = GoogleSQLLiteral.quotedIdentifier("a`\u{301}b\\")
        #expect(Array(quoted.unicodeScalars) == Array("`a\\`\u{301}b\\\\`".unicodeScalars))
    }
}
