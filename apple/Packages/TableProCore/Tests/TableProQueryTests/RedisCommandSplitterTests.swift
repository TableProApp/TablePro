import Foundation
import TableProQuery
import Testing

struct RedisCommandSplitterTests {
    private func texts(_ script: String) -> [String] {
        RedisCommandSplitter.commands(in: script).map { $0.text }
    }

    private func command(at caret: Int, in script: String) -> String? {
        RedisCommandSplitter.command(at: caret, in: script)?.text
    }

    @Test("A semicolon ends a command and is not part of it")
    func semicolonEndsACommand() {
        #expect(texts("GET a; GET b;") == ["GET a", "GET b"])
        #expect(texts("GET a;GET b") == ["GET a", "GET b"])
    }

    @Test("A line break ends a command, CRLF and a lone CR as one break each")
    func lineBreakEndsACommand() {
        #expect(texts("GET a\nGET b") == ["GET a", "GET b"])
        #expect(texts("GET a\r\nGET b\r\n") == ["GET a", "GET b"])
        #expect(texts("GET a\rGET b") == ["GET a", "GET b"])
    }

    @Test("A semicolon or a line break inside quotes stays in the command")
    func quotedSeparatorsStayInTheCommand() {
        #expect(texts("SET k \"a;b\"; SET j 'c\nd'\nGET k") == ["SET k \"a;b\"", "SET j 'c\nd'", "GET k"])
        #expect(texts("SET k \"it's; fine\"") == ["SET k \"it's; fine\""])
    }

    @Test("A backslash escapes the quote, semicolon or line break after it")
    func backslashEscapesTheNextCharacter() {
        #expect(texts("SET k \"a\\\";b\"; GET k") == ["SET k \"a\\\";b\"", "GET k"])
        #expect(texts("SET k a\\;b; GET k") == ["SET k a\\;b", "GET k"])
    }

    @Test("A backslash before LF or CRLF keeps one command, as the driver parses it")
    func backslashBeforeALineBreak() {
        #expect(texts("SET k a\\\nb") == ["SET k a\\\nb"])
        #expect(texts("SET k a\\\r\nb") == ["SET k a\\\r\nb"])
        #expect(texts("SET k a\\\nb\nGET k") == ["SET k a\\\nb", "GET k"])
    }

    @Test("An unclosed quote runs to the end of the text")
    func unclosedQuoteRunsToTheEnd() {
        #expect(texts("SET k \"abc; GET k\nDEL k") == ["SET k \"abc; GET k\nDEL k"])
        #expect(texts("GET a\nSET k 'x") == ["GET a", "SET k 'x"])
    }

    @Test("Blank lines, spaces and empty commands give nothing")
    func blanksGiveNothing() {
        #expect(texts("").isEmpty)
        #expect(texts("  \n\t\n ; ;\r\n").isEmpty)
        #expect(texts("\n\n  GET a  \n\n") == ["GET a"])
    }

    @Test("A command's range covers its trimmed text in UTF-16 units")
    func rangesAreTrimmedUTF16() {
        #expect(RedisCommandSplitter.commands(in: "  GET a  ;") == [
            RedisCommandSplitter.Command(text: "GET a", range: NSRange(location: 2, length: 5)),
        ])
        #expect(RedisCommandSplitter.commands(in: "SET 😀 1\nGET 😀") == [
            RedisCommandSplitter.Command(text: "SET 😀 1", range: NSRange(location: 0, length: 8)),
            RedisCommandSplitter.Command(text: "GET 😀", range: NSRange(location: 9, length: 6)),
        ])
    }

    @Test("A caret belongs to the command its semicolon ends, its line's end, or the next command after blanks")
    func caretRule() {
        let script = "GET a; GET b\n\nGET c  \n"
        let expected: [(Int, String?)] = [
            (0, "GET a"), (5, "GET a"), (6, "GET a"), (7, "GET b"), (12, "GET b"),
            (13, "GET c"), (14, "GET c"), (20, "GET c"), (21, "GET c"), (22, nil),
        ]
        for (caret, text) in expected {
            #expect(command(at: caret, in: script) == text, "caret \(caret)")
        }
    }

    @Test("A caret after the last command, or in text with none, has no command")
    func caretPastEveryCommand() {
        #expect(command(at: 6, in: "GET a\n") == nil)
        #expect(command(at: 7, in: "GET a; ") == nil)
        #expect(command(at: 6, in: "GET a;") == "GET a")
        #expect(command(at: 0, in: "") == nil)
        #expect(command(at: 1, in: " \n ") == nil)
    }

    @Test("A caret inside a quoted line break belongs to the quoted command")
    func caretInsideAQuotedLineBreak() {
        let script = "SET k \"a\nb\"\nGET k"
        #expect(RedisCommandSplitter.command(at: 9, in: script)
            == RedisCommandSplitter.Command(text: "SET k \"a\nb\"", range: NSRange(location: 0, length: 11)))
        #expect(RedisCommandSplitter.command(at: 12, in: script)
            == RedisCommandSplitter.Command(text: "GET k", range: NSRange(location: 12, length: 5)))
    }
}
