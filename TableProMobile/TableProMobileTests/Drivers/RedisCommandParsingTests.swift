import Foundation
@testable import TableProMobile
import Testing

@Suite("Redis command parsing")
struct RedisCommandParsingTests {
    private func parse(_ input: String) -> [String] {
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
        #expect(parse("\n\r\n\r").isEmpty)
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
        #expect(parse("").isEmpty)
        #expect(parse(" \t ").isEmpty)
    }
}
