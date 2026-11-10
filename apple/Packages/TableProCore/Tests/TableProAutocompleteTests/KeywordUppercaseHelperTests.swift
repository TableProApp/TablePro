import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct KeywordUppercaseHelperTests {
    // MARK: - isWordBoundary

    @Test("Space, tab and newline are word boundaries", arguments: [" ", "\t", "\n"])
    func whitespaceIsBoundary(_ string: String) {
        #expect(KeywordUppercaseHelper.isWordBoundary(string))
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

    @Test("The empty string and digits are not word boundaries", arguments: ["", "5"])
    func notBoundary(_ string: String) {
        #expect(!KeywordUppercaseHelper.isWordBoundary(string))
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
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 20, grammar: .ansi))
    }

    @Test("Outside single-quoted string")
    func outsideSingleQuote() {
        let text: NSString = "SELECT 'hello' select "
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 22, grammar: .ansi))
    }

    @Test("Inside double-quoted identifier")
    func insideDoubleQuote() {
        let text: NSString = "SELECT \"select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 14, grammar: .ansi))
    }

    @Test("Inside backtick identifier")
    func insideBacktick() {
        let text: NSString = "SELECT `select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 14, grammar: .backtickQuotes))
    }

    @Test("Backslash-escaped quote does not end string")
    func backslashEscapedQuote() {
        let text: NSString = "SELECT 'it\\'s select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 20, grammar: .backslashEscapesInSingleQuotes))
    }

    // MARK: - isInsideProtectedContext: Comments

    @Test("Inside line comment (--)")
    func insideLineComment() {
        let text: NSString = "SELECT -- select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16, grammar: .ansi))
    }

    @Test("After line comment on new line")
    func afterLineCommentNewLine() {
        let text: NSString = "-- comment\nselect"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 17, grammar: .ansi))
    }

    @Test("Inside block comment")
    func insideBlockComment() {
        let text: NSString = "SELECT /* select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16, grammar: .ansi))
    }

    @Test("After closed block comment")
    func afterClosedBlockComment() {
        let text: NSString = "/* comment */ select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 19, grammar: .ansi))
    }

    @Test("Inside MySQL hash comment (#)")
    func insideMySQLHashComment() {
        let text: NSString = "SELECT # select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 15, grammar: .hashLineComments))
    }

    @Test("Hash inside string is not a comment")
    func hashInsideStringNotComment() {
        let text: NSString = "SELECT 'test#' select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 21, grammar: .ansi))
    }

    // MARK: - isInsideProtectedContext: Dollar-Quoting (PostgreSQL)

    @Test("Inside dollar-quoted string")
    func insideDollarQuote() {
        let text: NSString = "SELECT $$ select"
        #expect(KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16, grammar: .taggedDollarQuotes))
    }

    @Test("After closed dollar-quoted string")
    func afterClosedDollarQuote() {
        let text: NSString = "$$ body $$ select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 17, grammar: .taggedDollarQuotes))
    }

    @Test("Single dollar is not a quote")
    func singleDollarNotQuote() {
        let text: NSString = "SELECT $5 select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 16, grammar: .taggedDollarQuotes))
    }

    // MARK: - isInsideProtectedContext: Edge Cases

    @Test("Position 0 is never protected")
    func positionZeroNotProtected() {
        let text: NSString = "select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 0, grammar: .ansi))
    }

    @Test("Empty string at position 0")
    func emptyStringNotProtected() {
        let text: NSString = ""
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 0, grammar: .ansi))
    }

    @Test("Nested quotes: double inside single are ignored")
    func nestedDoubleInSingle() {
        let text: NSString = "SELECT '\"hello\"' select"
        #expect(!KeywordUppercaseHelper.isInsideProtectedContext(text, at: 23, grammar: .ansi))
    }

    // MARK: - keywordBeforePosition

    @Test("Detects lowercase keyword")
    func detectsLowercaseKeyword() {
        let text: NSString = "select "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6, grammar: .ansi)
        #expect(result != nil)
        #expect(result?.word == "select")
        #expect(result?.range == NSRange(location: 0, length: 6))
    }

    @Test("Returns nil for already uppercase keyword")
    func alreadyUppercaseReturnsNil() {
        let text: NSString = "SELECT "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6, grammar: .ansi)
        #expect(result == nil)
    }

    @Test("Detects mixed-case keyword")
    func detectsMixedCase() {
        let text: NSString = "Select "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6, grammar: .ansi)
        #expect(result != nil)
        #expect(result?.word == "Select")
    }

    @Test("Returns nil for non-keyword")
    func nonKeywordReturnsNil() {
        let text: NSString = "foobar "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 6, grammar: .ansi)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside string literal")
    func keywordInsideStringReturnsNil() {
        let text: NSString = "'select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 7, grammar: .ansi)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside comment")
    func keywordInsideCommentReturnsNil() {
        let text: NSString = "-- select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 9, grammar: .ansi)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside dollar-quote")
    func keywordInsideDollarQuoteReturnsNil() {
        let text: NSString = "$$ select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 9, grammar: .taggedDollarQuotes)
        #expect(result == nil)
    }

    @Test("Returns nil for keyword inside hash comment")
    func keywordInsideHashCommentReturnsNil() {
        let text: NSString = "# select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 8, grammar: .hashLineComments)
        #expect(result == nil)
    }

    @Test("Detects keyword after other text")
    func keywordAfterOtherText() {
        let text: NSString = "SELECT * from "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 13, grammar: .ansi)
        #expect(result != nil)
        #expect(result?.word == "from")
        #expect(result?.range == NSRange(location: 9, length: 4))
    }

    @Test("Returns nil for partial identifier containing keyword")
    func identifierContainingKeywordReturnsNil() {
        let text: NSString = "select_count "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 12, grammar: .ansi)
        #expect(result == nil)
    }

    @Test("Returns nil at position 0")
    func positionZeroReturnsNil() {
        let text: NSString = "select"
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 0, grammar: .ansi)
        #expect(result == nil)
    }

    @Test("Detects keyword followed by parenthesis")
    func keywordBeforeParen() {
        // "count" is not a keyword, but "where" is
        let text2: NSString = "where("
        let result2 = KeywordUppercaseHelper.keywordBeforePosition(text2, at: 5, grammar: .ansi)
        #expect(result2 != nil)
        #expect(result2?.word == "where")
    }

    @Test("Returns nil for empty word (consecutive spaces)")
    func emptyWordReturnsNil() {
        let text: NSString = "SELECT  "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 8, grammar: .ansi)
        #expect(result == nil)
    }

    @Test("Keyword with digits is not a keyword")
    func keywordWithDigitsNotKeyword() {
        let text: NSString = "select2 "
        let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: 7, grammar: .ansi)
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
            let result = KeywordUppercaseHelper.keywordBeforePosition(text, at: text.length, grammar: .ansi)
            #expect(result != nil, "Expected '\(kw)' to be detected as a keyword")
        }
    }

    // MARK: - Engine grammar

    private func folds(_ text: String, _ grammar: SQLLexicalGrammar) -> Bool {
        let source = text as NSString
        return KeywordUppercaseHelper.keywordBeforePosition(source, at: source.length, grammar: grammar) != nil
    }

    @Test("A backslash before a closing quote keeps the literal open only where the engine escapes with it")
    func backslashFollowsTheGrammar() {
        let text = "VALUES ('C:\\', 'order from"
        #expect(!folds(text, .ansi))
        #expect(folds(text, .backslashEscapesInSingleQuotes))
    }

    @Test("A literal that opens more than 2,000 characters back still protects the word")
    func longLiteral() {
        let text = "SELECT '" + String(repeating: "x ", count: 2_000) + "from"
        #expect(!folds(text, .ansi))
    }

    @Test("A bracket name protects the word only where brackets quote")
    func bracketName() {
        #expect(!folds("SELECT [group", .bracketQuotedIdentifiers))
        #expect(folds("SELECT a[group", .ansi))
    }

    @Test("A tagged dollar quote protects the word, and an inner $$ does not end it")
    func taggedDollarQuote() {
        #expect(!folds("DO $fn$ begin $$ select", .taggedDollarQuotes))
        #expect(folds("DO $fn$ x $fn$ select", .taggedDollarQuotes))
    }

    @Test("A # starts a comment only where the engine reads one")
    func hashFollowsTheGrammar() {
        #expect(folds("SELECT a #> b from", .ansi))
        #expect(!folds("SELECT a # b from", .hashLineComments))
    }

    @Test("The body of an executable comment is code")
    func executableComment() {
        let mySQL: SQLLexicalGrammar = [.executableComments, .backtickQuotes]
        #expect(folds("/*!50001 select", mySQL))
        #expect(!folds("/* select", mySQL))
    }
}
