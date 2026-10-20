import Foundation
@testable import TableProMobile
import TableProModels
import TableProQuery
import Testing

@Suite("Redis command parsing")
struct RedisCommandParsingTests {
    private func parse(_ input: String) -> [String]? {
        RedisDriver.parseRedisCommand(input)
    }

    @Test("a newline separates arguments")
    func newlineSeparates() {
        #expect(parse("DEL a\nDEL b") == ["DEL", "a", "DEL", "b"])
        #expect(parse("LPUSH l x\nLPUSH l y") == ["LPUSH", "l", "x", "LPUSH", "l", "y"])
    }

    @Test("a CRLF line break separates arguments")
    func crlfSeparates() {
        #expect(parse("SET k v\r\nGET k") == ["SET", "k", "v", "GET", "k"])
    }

    @Test("a lone carriage return separates arguments")
    func carriageReturnSeparates() {
        #expect(parse("SET k v\rGET k") == ["SET", "k", "v", "GET", "k"])
    }

    @Test("leading and trailing line breaks add no argument")
    func surroundingLineBreaks() {
        #expect(parse("\n\r\nGET k\n\n") == ["GET", "k"])
        #expect(parse("\n\r\n\r")?.isEmpty == true)
    }

    @Test("a double-quoted argument keeps its line breaks")
    func doubleQuotedKeepsLineBreaks() {
        #expect(parse("SET k \"line1\nline2\"") == ["SET", "k", "line1\nline2"])
        #expect(parse("SET k \"a\r\nb\"") == ["SET", "k", "a\r\nb"])
    }

    @Test("a single-quoted argument keeps its line breaks")
    func singleQuotedKeepsLineBreaks() {
        #expect(parse("SET k 'a\nb'") == ["SET", "k", "a\nb"])
    }

    @Test("spaces and tabs still separate arguments")
    func spacesAndTabsSeparate() {
        #expect(parse("  GET\t\tk  ") == ["GET", "k"])
    }

    @Test("a quoted argument keeps its spaces")
    func quotedKeepsSpaces() {
        #expect(parse("SET greeting \"hello world\"") == ["SET", "greeting", "hello world"])
        #expect(parse("SET greeting 'hello world'") == ["SET", "greeting", "hello world"])
    }

    @Test("a backslash escapes the next character")
    func backslashEscapes() {
        #expect(parse("SET k \"say \\\"hi\\\"\"") == ["SET", "k", "say \"hi\""])
        #expect(parse("SET k a\\ b") == ["SET", "k", "a b"])
    }

    @Test("an empty quoted argument is kept, so a write receives every value it was given")
    func emptyQuotedArgumentIsKept() {
        #expect(parse("LPUSH l \"\" x") == ["LPUSH", "l", "", "x"])
        #expect(parse("SET k ''") == ["SET", "k", ""])
        #expect(parse("HSET h f \"\"\nGET k") == ["HSET", "h", "f", "", "GET", "k"])
    }

    @Test("empty and blank input give no arguments")
    func emptyInput() {
        #expect(parse("")?.isEmpty == true)
        #expect(parse(" \t ")?.isEmpty == true)
    }

    @Test("an unclosed quote gives no command, so a cut value is never stored")
    func unclosedQuoteGivesNil() {
        #expect(parse("SET greeting \"hello") == nil)
        #expect(parse("SET greeting 'hello") == nil)
        #expect(parse("SET k \"a\\\"") == nil)
    }

    @Test("a backslash before a line break keeps one command, split and parsed alike")
    func escapedLineBreakMatchesSplitter() throws {
        try expectOneCommand("SET k a\\\nb", parsesTo: ["SET", "k", "a\nb"])
        try expectOneCommand("SET k a\\\r\nb", parsesTo: ["SET", "k", "a\r\nb"])
    }

    @Test("Run on a command ending in an escaped blank sends that blank in its key")
    func escapedTrailingBlankReachesTheDriver() {
        let script = "DEL victim\\ ; GET other"
        let target = QueryRunTarget.resolve(
            in: script, selection: NSRange(location: 2, length: 0), databaseType: .redis, session: nil
        )
        #expect(target == .statement("DEL victim\\ ", range: NSRange(location: 0, length: 12)))
        for text in ["DEL victim\\ ", script] {
            let runText = QueryScript.trimmed(text, databaseType: .redis)
            let units = QueryScript.plan(runText, databaseType: .redis, sendsBatchesWhole: false).units
            let arguments = units.first.flatMap { parse($0.sql) }
            #expect(arguments == ["DEL", "victim "])
        }
    }

    private func expectOneCommand(_ script: String, parsesTo expected: [String]) throws {
        let commands = RedisCommandSplitter.commands(in: script)
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(parse(command.text) == expected)
    }
}
