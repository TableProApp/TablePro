import Foundation
import TableProSQLGrammar
import Testing

@Suite("SQL non-code spans")
struct SQLNonCodeSpanTests {
    private func end(_ text: String, at index: Int = 0, _ grammar: SQLLexicalGrammar) -> Int? {
        SQLNonCodeSpan.span(at: index, in: text as NSString, grammar: grammar)?.end
    }

    @Test("A backslash keeps a quote open only where the grammar says so")
    func backslashFollowsTheGrammar() {
        #expect(end("'a\\' b'", .ansi) == 4)
        #expect(end("'a\\' b'", .backslashEscapesInSingleQuotes) == 7)
        #expect(end("\"a\\\" b\"", .backslashEscapesInSingleQuotes) == 4)
        #expect(end("`a\\` b`", [.backtickQuotes, .backslashEscapesInSingleQuotes]) == 4)
        #expect(end("`a\\` b`", [.backtickQuotes, .backslashEscapesInBackticks]) == 7)
    }

    @Test("A backtick quotes only where the grammar reads it")
    func backtickFollowsTheGrammar() {
        #expect(end("`a;b`", .ansi) == nil)
        #expect(end("`a;b`", .backtickQuotes) == 5)
    }

    @Test("Block comments nest only where the grammar says so")
    func nestingFollowsTheGrammar() {
        let text = "/* a /* b */ c */ d"
        #expect(end(text, .ansi) == 12)
        #expect(end(text, .nestedBlockComments) == 17)
    }

    @Test("Brackets quote an identifier only where the grammar says so, and ]] escapes only on T-SQL")
    func bracketsFollowTheGrammar() {
        #expect(end("[a]]b] c", .ansi) == nil)
        #expect(end("[a]]b] c", .bracketQuotedIdentifiers) == 3)
        #expect(end("[a]]b] c", [.bracketQuotedIdentifiers, .doubledClosingBracketEscapes]) == 6)
    }

    @Test("Line comments start with #, // and -- as the grammar reads them")
    func lineCommentsFollowTheGrammar() {
        #expect(end("# a\nb", .ansi) == nil)
        #expect(end("# a\nb", .hashLineComments) == 3)
        #expect(end("// a\nb", .ansi) == nil)
        #expect(end("// a\nb", .doubleSlashLineComments) == 4)
        #expect(end("--a\nb", .ansi) == 3)
        #expect(end("--a\nb", .dashCommentsNeedWhitespace) == nil)
        #expect(end("-- a\nb", .dashCommentsNeedWhitespace) == 4)
        #expect(end("--", .dashCommentsNeedWhitespace) == 2)
    }

    @Test("A lone carriage return ends a line comment only where the engine ends it there")
    func carriageReturnFollowsTheGrammar() {
        #expect(end("-- a\rb\nc", .ansi) == 6)
        #expect(end("-- a\rb\nc", .carriageReturnEndsLineComments) == 4)
    }

    @Test("E'...' escapes with a backslash, and only where a word could start")
    func escapeStringPrefix() {
        #expect(end("E'\\'' x", .escapeStringPrefix) == 5)
        #expect(end("xE'\\'' x", at: 1, .escapeStringPrefix) == nil)
        #expect(end("E'\\'' x", .ansi) == nil)
    }

    @Test("q'[...]' runs to its closing delimiter, and only where a word could start")
    func alternativeQuoting() {
        #expect(end("q'[it's]' x", .alternativeQuoting) == 9)
        #expect(end("nq'{a'b}' x", .alternativeQuoting) == 9)
        #expect(end("xq'[it's]'", at: 1, .alternativeQuoting) == nil)
    }

    @Test("Tagged dollar quotes take non-ASCII tags, untagged ones take only $$")
    func dollarQuoteStyles() {
        #expect(end("$ü$a;b$ü$ c", .taggedDollarQuotes) == 9)
        #expect(end("$tag$a;b$tag$ c", .taggedDollarQuotes) == 13)
        #expect(end("$tag$a;b$tag$ c", .untaggedDollarQuotes) == nil)
        #expect(end("$$a;b$$ c", .untaggedDollarQuotes) == 7)
        #expect(end("$1", .taggedDollarQuotes) == nil)
    }

    @Test("A dollar glued to an identifier, ASCII or not, never opens a body")
    func gluedDollarIsIdentifier() {
        #expect(end("x$$;$$", at: 1, .taggedDollarQuotes) == nil)
        #expect(end("é$$;$$", at: 1, .taggedDollarQuotes) == nil)
        #expect(end(" $$;$$", at: 1, .taggedDollarQuotes) == 6)
    }

    @Test("A triple-quoted literal holds a lone quote")
    func tripleQuotes() {
        #expect(end("'''it's''' x", .tripleQuotedStrings) == 10)
        #expect(end("'''it's''' x", .ansi) == 6)
    }

    @Test("SQLite's $name(...) parameter runs to its ) or to whitespace")
    func parenthesizedParameters() {
        #expect(end("$a('); x", .parenthesizedParameterNames) == 5)
        #expect(end("@a::b(;) x", .parenthesizedParameterNames) == 8)
        #expect(end("$ab(x y)", .parenthesizedParameterNames) == 5)
        #expect(end("$(x)", .parenthesizedParameterNames) == nil)
        #expect(end("$a('); x", .ansi) == nil)
    }

    @Test("A MySQL executable comment reads its body as SQL, so a quoted */ does not close it")
    func executableCommentIsQuoteAware() {
        let text = "/*!40101 , '*/' */ x"
        let span = SQLNonCodeSpan.span(at: 0, in: text as NSString, grammar: [.executableComments])
        #expect(span?.kind == .executableComment)
        #expect(span?.end == 18)
        #expect(SQLNonCodeSpan.end(at: 0, in: text as NSString, grammar: [.executableComments]) == nil)
        #expect(end(text, .ansi) == 14)
    }

    @Test("A span the text ends inside is reported unterminated")
    func unterminatedSpans() {
        let grammar: SQLLexicalGrammar = [.taggedDollarQuotes, .bracketQuotedIdentifiers]
        for text in ["'abc", "/* abc", "$$abc", "[abc", "'abc\\'"] {
            let span = SQLNonCodeSpan.span(at: 0, in: text as NSString, grammar: grammar.union(.backslashEscapesInSingleQuotes))
            #expect(span?.isTerminated == false, "\(text)")
        }
        #expect(SQLNonCodeSpan.span(at: 0, in: "'abc'" as NSString, grammar: .ansi)?.isTerminated == true)
    }

    @Test("The code projection keeps every offset and blanks every literal and comment")
    func codeProjectionKeepsOffsets() {
        let text = "SELECT 'a;b', \"c\" /* d */ FROM t -- e\nWHERE x = $$f$$"
        let code = SQLCodeProjection.code(of: text, grammar: .taggedDollarQuotes)
        #expect((code as NSString).length == (text as NSString).length)
        #expect(!code.contains("a;b"))
        #expect(!code.contains(" d "))
        #expect(code.contains("FROM t"))
        #expect(code.contains("WHERE x ="))
        #expect(!code.contains("f"))
    }

    @Test("Revealing an executable comment keeps its body as code under any grammar")
    func codeProjectionRevealsExecutableComments() {
        let text = "SELECT 1 /*!40101 DROP TABLE t */"
        #expect(!SQLCodeProjection.code(of: text, grammar: .ansi).contains("DROP"))
        #expect(SQLCodeProjection.code(of: text, grammar: .ansi, revealingExecutableComments: true).contains("DROP"))
    }
}
