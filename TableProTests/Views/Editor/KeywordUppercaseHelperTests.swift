import Foundation
@testable import TablePro
import Testing

@Suite("KeywordUppercaseHelper")
struct KeywordUppercaseHelperTests {

    // MARK: - isWordBoundary

    @Test("Space is a word boundary")
    func spaceIsBoundary() {
        #expect(KeywordUppercaseHelper.isWordBoundary(" "))
    }

    @Test("Tab is a word boundary")
    func tabIsBoundary() {
        #expect(KeywordUppercaseHelper.isWordBoundary("\t"))
    }

    @Test("Newline is a word boundary")
    func newlineIsBoundary() {
        #expect(KeywordUppercaseHelper.isWordBoundary("\n"))
    }

    @Test("Parentheses are word boundaries")
    func parensBoundary() {
        #expect(KeywordUppercaseHelper.isWordBoundary("("))
        #expect(KeywordUppercaseHelper.isWordBoundary(")"))
    }

    @Test("Comma and semicolon are word boundaries")
    func commaSemicolonBoundary() {
        #expect(KeywordUppercaseHelper.isWordBoundary(","))
        #expect(KeywordUppercaseHelper.isWordBoundary(";"))
    }

    @Test("Letters are not word boundaries")
    func lettersNotBoundary() {
        #expect(!KeywordUppercaseHelper.isWordBoundary("a"))
        #expect(!KeywordUppercaseHelper.isWordBoundary("Z"))
    }

    @Test("Multi-character strings are not word boundaries")
    func multiCharNotBoundary() {
        #expect(!KeywordUppercaseHelper.isWordBoundary("  "))
        #expect(!KeywordUppercaseHelper.isWordBoundary("ab"))
    }

    @Test("Empty string is not a word boundary")
    func emptyNotBoundary() {
        #expect(!KeywordUppercaseHelper.isWordBoundary(""))
    }

    @Test("Digits are not word boundaries")
    func digitsNotBoundary() {
        #expect(!KeywordUppercaseHelper.isWordBoundary("5"))
    }

    // MARK: - isWordCharacter

    @Test("Lowercase letters are word characters")
    func lowercaseWordChars() {
        #expect(KeywordUppercaseHelper.isWordCharacter(0x61)) // a
        #expect(KeywordUppercaseHelper.isWordCharacter(0x7A)) // z
    }

    @Test("Uppercase letters are word characters")
    func uppercaseWordChars() {
        #expect(KeywordUppercaseHelper.isWordCharacter(0x41)) // A
        #expect(KeywordUppercaseHelper.isWordCharacter(0x5A)) // Z
    }

    @Test("Digits are word characters")
    func digitsWordChars() {
        #expect(KeywordUppercaseHelper.isWordCharacter(0x30)) // 0
        #expect(KeywordUppercaseHelper.isWordCharacter(0x39)) // 9
    }

    @Test("Underscore is a word character")
    func underscoreWordChar() {
        #expect(KeywordUppercaseHelper.isWordCharacter(0x5F)) // _
    }

    @Test("Special chars are not word characters")
    func specialNotWordChars() {
        #expect(!KeywordUppercaseHelper.isWordCharacter(0x20)) // space
        #expect(!KeywordUppercaseHelper.isWordCharacter(0x2D)) // -
        #expect(!KeywordUppercaseHelper.isWordCharacter(0x2E)) // .
        #expect(!KeywordUppercaseHelper.isWordCharacter(0x40)) // @
    }

    // MARK: - isInsideProtectedContext: String Literals

    @Test("Inside single-quoted string")
    func insideSingleQuote() {
        let text: NSString = "SELECT 'hello select "
        // Position 20 is after "select " inside the string
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 20))
    }

    @Test("Outside single-quoted string")
    func outsideSingleQuote() {
        let text: NSString = "SELECT 'hello' select "
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 22))
    }

    @Test("Inside double-quoted identifier")
    func insideDoubleQuote() {
        let text: NSString = "SELECT \"select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 14))
    }

    @Test("Inside backtick identifier")
    func insideBacktick() {
        let text: NSString = "SELECT `select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 14))
    }

    @Test("Backslash-escaped quote does not end string")
    func backslashEscapedQuote() {
        let text: NSString = "SELECT 'it\\'s select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 20))
    }

    // MARK: - isInsideProtectedContext: Comments

    @Test("Inside line comment (--)")
    func insideLineComment() {
        let text: NSString = "SELECT -- select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16))
    }

    @Test("After line comment on new line")
    func afterLineCommentNewLine() {
        let text: NSString = "-- comment\nselect"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 17))
    }

    @Test("Inside block comment")
    func insideBlockComment() {
        let text: NSString = "SELECT /* select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16))
    }

    @Test("After closed block comment")
    func afterClosedBlockComment() {
        let text: NSString = "/* comment */ select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 19))
    }

    @Test("Inside MySQL hash comment (#)")
    func insideMySQLHashComment() {
        let text: NSString = "SELECT # select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 15))
    }

    @Test("Hash inside string is not a comment")
    func hashInsideStringNotComment() {
        let text: NSString = "SELECT 'test#' select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 21))
    }

    // MARK: - isInsideProtectedContext: Dollar-Quoting (PostgreSQL)

    @Test("Inside dollar-quoted string")
    func insideDollarQuote() {
        let text: NSString = "SELECT $$ select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16))
    }

    @Test("After closed dollar-quoted string")
    func afterClosedDollarQuote() {
        let text: NSString = "$$ body $$ select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 17))
    }

    @Test("Single dollar is not a quote")
    func singleDollarNotQuote() {
        let text: NSString = "SELECT $5 select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16))
    }

    // MARK: - isInsideProtectedContext: Edge Cases

    @Test("Position 0 is never protected")
    func positionZeroNotProtected() {
        let text: NSString = "select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 0))
    }

    @Test("Empty string at position 0")
    func emptyStringNotProtected() {
        let text: NSString = ""
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 0))
    }

    @Test("Nested quotes: double inside single are ignored")
    func nestedDoubleInSingle() {
        let text: NSString = "SELECT '\"hello\"' select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 23))
    }

    // MARK: - keywordBeforePosition

    @Test("Detects lowercase keyword")
    func detectsLowercaseKeyword() {
        let text: NSString = "select "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6)
        #expect(result != nil)
        #expect(result?.word == "select")
        #expect(result?.range == NSRange(location: 0, length: 6))
    }

    @Test("Returns nil for already uppercase keyword")
    func alreadyUppercaseReturnsNil() {
        let text: NSString = "SELECT "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6)
        #expect(result == nil)
    }

    @Test("Detects mixed-case keyword")
    func detectsMixedCase() {
        let text: NSString = "Select "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6)
        #expect(result != nil)
        #expect(result?.word == "Select")
    }

    @Test("Returns nil for non-keyword")
    func nonKeywordReturnsNil() {
        let text: NSString = "foobar "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside string literal")
    func keywordInsideStringReturnsNil() {
        let text: NSString = "'select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 7)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside comment")
    func keywordInsideCommentReturnsNil() {
        let text: NSString = "-- select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 9)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside dollar-quote")
    func keywordInsideDollarQuoteReturnsNil() {
        let text: NSString = "$$ select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 9)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside hash comment")
    func keywordInsideHashCommentReturnsNil() {
        let text: NSString = "# select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 8)
        #expect(result == nil)
    }

    @Test("Detects keyword after other text")
    func keywordAfterOtherText() {
        let text: NSString = "SELECT * from "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 13)
        #expect(result != nil)
        #expect(result?.word == "from")
        #expect(result?.range == NSRange(location: 9, length: 4))
    }

    @Test("Returns nil for partial identifier containing keyword")
    func identifierContainingKeywordReturnsNil() {
        let text: NSString = "select_count "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 12)
        #expect(result == nil)
    }

    @Test("Returns nil at position 0")
    func positionZeroReturnsNil() {
        let text: NSString = "select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 0)
        #expect(result == nil)
    }

    @Test("Detects keyword followed by parenthesis")
    func keywordBeforeParen() {
        let text: NSString = "count("
        // "count" is not a keyword, but "where" is
        let text2: NSString = "where("
        let result2 = KeywordUppercaseHelper.keywordBeforePosition(text2, at: 5)
        #expect(result2 != nil)
        #expect(result2?.word == "where")
    }

    @Test("Returns nil for empty word (consecutive spaces)")
    func emptyWordReturnsNil() {
        let text: NSString = "SELECT  "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 8)
        #expect(result == nil)
    }

    @Test("Keyword with digits is not a keyword")
    func keywordWithDigitsNotKeyword() {
        let text: NSString = "select2 "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 7)
        #expect(result == nil)
    }

    @Test("All major SQL keywords detected")
    func majorKeywordsDetected() {
        let keywords = ["select", "from", "where", "insert", "update", "delete", "create", "alter",
                        "drop", "join", "inner", "left", "right", "on", "group", "order", "having",
                        "limit", "offset", "union", "exists", "between", "like", "in", "is", "null",
                        "not", "and", "or", "as", "set", "into", "values", "begin", "commit", "rollback"]
        for kw in keywords {
            let text = kw as NSString
            let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: text.length)
            #expect(result != nil, "Expected '\(kw)' to be detected as a keyword")
        }
    }
}
