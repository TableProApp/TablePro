import Foundation
import TableProRedisCore
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

    @Test("Each line of the Redis CLI docs example is its own command")
    func docsExample() {
        let script = """
            SET mykey "hello" EX 60
            HGETALL myhash; LRANGE mylist 0 -1
            SCAN 0 MATCH user:* COUNT 100
            """
        #expect(texts(script) == [
            "SET mykey \"hello\" EX 60", "HGETALL myhash", "LRANGE mylist 0 -1", "SCAN 0 MATCH user:* COUNT 100",
        ])
    }

    @Test("A semicolon or a line break inside quotes stays in the command")
    func quotedSeparatorsStayInTheCommand() {
        #expect(texts("SET k \"a;b\"; SET j 'c\nd'\nGET k") == ["SET k \"a;b\"", "SET j 'c\nd'", "GET k"])
        #expect(texts("SET k \"it's; fine\"") == ["SET k \"it's; fine\""])
    }

    @Test("A backslash escapes inside double quotes, and only a quote inside single quotes")
    func backslashInsideQuotes() {
        #expect(texts("SET k \"a\\\";b\"; GET k") == ["SET k \"a\\\";b\"", "GET k"])
        #expect(texts("SET k 'it\\'s; ok'; GET k") == ["SET k 'it\\'s; ok'", "GET k"])
        #expect(texts("SET k 'a\\\\'; DEL j '") == ["SET k 'a\\\\'; DEL j '"])
    }

    @Test("A backslash outside quotes is a plain byte, as redis-cli reads it")
    func backslashOutsideQuotes() {
        #expect(texts("SET k a\\;b; GET k") == ["SET k a\\", "b", "GET k"])
        #expect(texts("DEL victim\\\nGET x") == ["DEL victim\\", "GET x"])
        #expect(texts("SET k a\\\r\nb") == ["SET k a\\", "b"])
    }

    @Test("A quote followed by a combining mark still opens")
    func quoteBeforeACombiningMark() {
        #expect(texts("SET k \"\u{301}x; y\"; DEL other") == ["SET k \"\u{301}x; y\"", "DEL other"])
    }

    @Test("Text right after a closing quote spoils its command and not the next one")
    func badClosingQuoteKeepsTheNextCommand() {
        #expect(texts("SET k \"a\"b; GET k") == ["SET k \"a\"b", "GET k"])
    }

    @Test("An unclosed quote runs to the end of the text")
    func unclosedQuoteRunsToTheEnd() {
        #expect(texts("SET k \"abc; GET k\nDEL k") == ["SET k \"abc; GET k\nDEL k"])
        #expect(texts("GET a\nSET k 'x") == ["GET a", "SET k 'x"])
        #expect(texts("SET k \"abc\\\"\nGET k") == ["SET k \"abc\\\"\nGET k"])
    }

    @Test("Blank lines, spaces and empty commands give nothing")
    func blanksGiveNothing() {
        #expect(texts("").isEmpty)
        #expect(texts("  \n\t\n ; ;\r\n\u{0B}\u{0C}").isEmpty)
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

    @Test("Commands built from quoted arguments split and parse back to those arguments")
    func quotedCommandsRoundTrip() {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        let alphabet: [UInt8] = Array(" \t\n\r;\"'\\x41a".utf8) + [0x00, 0x0B, 0x0C, 0xC3, 0xA9, 0xFF]
        let separators = [";", "\n", "\r\n", " ; ", "\n\n", ";\r"]
        for _ in 0 ..< 300 {
            let commands: [[Data]] = (0 ..< 1 + next(4)).map { _ in
                (0 ..< 1 + next(4)).map { _ in Data((0 ..< next(6)).map { _ in alphabet[next(alphabet.count)] }) }
            }
            let script = commands
                .map { $0.map { RedisArgumentCodec.quote($0) }.joined(separator: " ") }
                .joined(separator: separators[next(separators.count)])
            let parsed = RedisCommandSplitter.commands(in: script).map { RedisArgumentCodec.split($0.text) }
            #expect(parsed == commands.map { Optional($0) }, "\(script.debugDescription)")
        }
    }
}

struct RedisSingleCommandTests {
    @Test("One command gives its arguments, with or without a closing semicolon")
    func oneCommand() {
        #expect(RedisSingleCommand("SET k \"a b\"") == .arguments([Data("SET".utf8), Data("k".utf8), Data("a b".utf8)]))
        #expect(RedisSingleCommand(" GET k; ") == .arguments([Data("GET".utf8), Data("k".utf8)]))
    }

    @Test("Two commands are refused instead of read as one, so a second DEL never deletes a key named DEL")
    func severalCommands() {
        #expect(RedisSingleCommand("DEL a\nDEL b") == .severalCommands)
        #expect(RedisSingleCommand("GET a; GET b") == .severalCommands)
    }

    @Test("Blank text and lone semicolons hold no command")
    func empty() {
        #expect(RedisSingleCommand("") == .empty)
        #expect(RedisSingleCommand(" ;\n ; ") == .empty)
    }

    @Test("An unclosed quote, or text after a closing quote, is refused")
    func unbalanced() {
        #expect(RedisSingleCommand("SET k \"abc") == .unbalancedQuotes)
        #expect(RedisSingleCommand("SET k 'abc") == .unbalancedQuotes)
        #expect(RedisSingleCommand("SET k \"a\"b") == .unbalancedQuotes)
    }

    @Test("A trailing backslash outside quotes stays in the key")
    func trailingBackslash() {
        #expect(RedisSingleCommand("DEL victim\\") == .arguments([Data("DEL".utf8), Data("victim\\".utf8)]))
    }

    @Test("Escapes decode to the bytes the server stores")
    func escapes() {
        #expect(RedisSingleCommand("SET k \"a\\nb\\x00\\xff\"")
            == .arguments([Data("SET".utf8), Data("k".utf8), Data([0x61, 0x0A, 0x62, 0x00, 0xFF])]))
    }
}
