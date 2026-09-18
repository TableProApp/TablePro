import Foundation
import TableProGoogleCloud
import Testing

@Suite("GoogleSQLLiteral")
struct GoogleSQLLiteralTests {
    @Test("An injection attempt stays inside the literal")
    func injectionStaysQuoted() {
        #expect(GoogleSQLLiteral.quotedString("x' OR TRUE --") == #"'x\' OR TRUE --'"#)
        #expect(GoogleSQLLiteral.quotedString(#"x\' OR TRUE --"#) == #"'x\\\' OR TRUE --'"#)
    }

    @Test("Doubled quotes are not the GoogleSQL escape")
    func apostropheIsBackslashEscaped() {
        #expect(GoogleSQLLiteral.quotedString("O'Brien") == #"'O\'Brien'"#)
        #expect(GoogleSQLLiteral.quotedString("say \"hi\"") == #"'say \"hi\"'"#)
    }

    @Test("Line breaks and tabs use their short escapes")
    func whitespaceControls() {
        #expect(GoogleSQLLiteral.quotedString("a\nb") == #"'a\nb'"#)
        #expect(GoogleSQLLiteral.quotedString("a\r\nb") == #"'a\r\nb'"#)
        #expect(GoogleSQLLiteral.quotedString("a\tb") == #"'a\tb'"#)
    }

    @Test("NUL, other controls and DEL become two-digit hex escapes")
    func hexEscapes() {
        #expect(GoogleSQLLiteral.quotedString("a\u{0}b") == #"'a\x00b'"#)
        #expect(GoogleSQLLiteral.quotedString("\u{1}\u{1F}") == #"'\x01\x1f'"#)
        #expect(GoogleSQLLiteral.quotedString("x\u{7F}") == #"'x\x7f'"#)
    }

    @Test("A trailing backslash cannot escape the closing quote")
    func trailingBackslash() {
        #expect(GoogleSQLLiteral.quotedString(#"C:\"#) == #"'C:\\'"#)
        #expect(GoogleSQLLiteral.quotedIdentifier(#"odd\"#) == #"`odd\\`"#)
    }

    @Test("Backticks are left alone in strings and escaped in identifiers")
    func backticks() {
        #expect(GoogleSQLLiteral.quotedString("a`b") == "'a`b'")
        #expect(GoogleSQLLiteral.quotedIdentifier("a`b") == #"`a\`b`"#)
        #expect(GoogleSQLLiteral.quotedIdentifier("x` OR TRUE --") == #"`x\` OR TRUE --`"#)
    }

    @Test("Identifiers keep ordinary names intact")
    func plainIdentifier() {
        #expect(GoogleSQLLiteral.quotedIdentifier("Singers") == "`Singers`")
        #expect(GoogleSQLLiteral.quotedIdentifier("select") == "`select`")
        #expect(GoogleSQLLiteral.quotedIdentifier("it's") == #"`it\'s`"#)
        #expect(GoogleSQLLiteral.quotedIdentifier("a\nb") == #"`a\nb`"#)
    }

    @Test("Non-ASCII text is written as is")
    func unicode() {
        #expect(GoogleSQLLiteral.quotedString("café 日本 🙂") == "'café 日本 🙂'")
    }

    @Test("The string body matches the quoted string without its quotes")
    func bodyMatchesQuoted() {
        let value = "it's\n\u{0}\\"
        #expect("'" + GoogleSQLLiteral.escapedStringBody(value) + "'" == GoogleSQLLiteral.quotedString(value))
    }

    @Test("Bytes become a FROM_BASE64 call")
    func bytes() {
        #expect(GoogleSQLLiteral.bytesLiteral(Data([0, 0xFF, 0x10])) == "FROM_BASE64('AP8Q')")
        #expect(GoogleSQLLiteral.bytesLiteral(Data()) == "FROM_BASE64('')")
    }

    @Test("LIKE metacharacters are escaped with a backslash")
    func likePattern() {
        #expect(GoogleSQLLiteral.likePatternBody("50%") == #"50\%"#)
        #expect(GoogleSQLLiteral.likePatternBody("a_b") == #"a\_b"#)
        #expect(GoogleSQLLiteral.likePatternBody(#"C:\dir"#) == #"C:\\dir"#)
        #expect(GoogleSQLLiteral.likePatternBody("plain") == "plain")
    }
}
