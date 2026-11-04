import Foundation
import TableProSQLQuoting
import Testing

struct SQLQuotingTests {
    @Test("A quote a combining mark follows is still doubled", arguments: [
        "\u{301}", "\u{200C}", "\u{200D}", "\u{FE0F}", "\u{FF9E}", "\u{1F3FB}",
    ])
    func combiningMarkAfterQuote(mark: String) {
        #expect(SQLQuoting.stringLiteral("a'\(mark) OR 1=1") == "'a''\(mark) OR 1=1'")
        #expect(SQLQuoting.identifier("a\"\(mark)b") == "\"a\"\"\(mark)b\"")
        #expect(SQLQuoting.identifier("a`\(mark)b", quote: .backtick) == "`a``\(mark)b`")
        #expect(SQLQuoting.identifier("a]\(mark)b", quote: .bracket) == "[a]]\(mark)b]")
    }

    @Test("A bracket name doubles only the closing bracket")
    func bracketDoublesClose() {
        #expect(SQLQuoting.identifier("[a]", quote: .bracket) == "[[a]]]")
    }

    @Test("A backslash identifier escapes the backslash and the quote")
    func backslashIdentifier() {
        #expect(SQLQuoting.identifier(#"a\`b"#, quote: .backtick, backslashEscapes: true) == #"`a\\\`b`"#)
    }

    @Test("Standard literals double quotes, keep backslashes and drop NUL")
    func standardLiteral() {
        #expect(SQLQuoting.stringLiteral("it's\\\0x") == #"'it''s\x'"#)
    }

    @Test("Backslash literals double the backslash and the quote, and MySQL's set also names its controls")
    func backslashLiteral() {
        let value = "a\\'\0\u{08}\n\r\t\u{1A}"
        #expect(SQLQuoting.stringLiteral(value, escapes: .backslash) == #"'a\\''\0"# + "\u{08}\n\r\t\u{1A}'")
        #expect(SQLQuoting.stringLiteral(value, escapes: .mysql) == #"'a\\''\0\b\n\r\t\Z'"#)
    }

    @Test("NUL before a digit is written so no engine reads an octal escape")
    func nulBeforeADigit() {
        #expect(SQLQuoting.stringLiteral("\0" + "12", escapes: .backslash) == #"'\x0012'"#)
        #expect(SQLQuoting.stringLiteral("\0" + "12", escapes: .mysql) == #"'\012'"#)
    }

    @Test("A GoogleSQL literal starting with a quote cannot open a triple-quoted one")
    func googleSQLLiteral() {
        #expect(SQLQuoting.stringLiteral("''x", escapes: .googleSQL) == #"'\'\'x'"#)
        #expect(SQLQuoting.stringLiteral("\0" + "12\u{07}", escapes: .googleSQL) == #"'\x0012\x07'"#)
    }

    @Test("A LIKE pattern escapes its metacharacters and the escape itself")
    func likePattern() {
        #expect(SQLQuoting.likePattern(#"50%_a\"#) == #"50\%\_a\\"#)
        #expect(SQLQuoting.likePattern("a[b%", escape: "!", metacharacters: ["%", "_", "["]) == "a![b!%")
    }

    @Test("A body that could close a dollar quote early is not dollar-quoted", arguments: [
        "return x * 2; // $$; GRANT ALL PERMISSIONS ON ALL KEYSPACES TO mallory; //",
        "x $$\u{301} y",
        "ends in $",
    ])
    func dollarQuotedRefusesACloser(body: String) {
        #expect(SQLQuoting.dollarQuoted(body) == nil)
    }

    @Test("A plain body is dollar-quoted as it is")
    func dollarQuotedKeepsPlainBody() {
        #expect(SQLQuoting.dollarQuoted("return a + '$';") == "$$return a + '$';$$")
    }

    @Test("Line comment text holds no line break", arguments: [
        "a\nDROP TABLE t", "a\r\nb", "a\u{2028}b", "a\u{85}b", "a\u{0C}b", "a\n\u{301}b",
    ])
    func lineCommentText(text: String) {
        let breaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
        #expect(!SQLQuoting.lineCommentText(text).unicodeScalars.contains { breaks.contains($0) })
    }
}
