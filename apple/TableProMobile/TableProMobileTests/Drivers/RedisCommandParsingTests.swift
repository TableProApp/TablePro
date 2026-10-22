import Foundation
@testable import TableProMobile
import TableProModels
import TableProQuery
import TableProRedisCore
import Testing

struct RedisCommandParsingTests {
    private func parse(_ input: String) -> [String]? {
        guard let arguments = try? RedisDriver.commandArguments(input) else { return nil }
        return arguments.map { String(decoding: $0, as: UTF8.self) }
    }

    private func error(_ input: String) -> String? {
        do {
            _ = try RedisDriver.commandArguments(input)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test("a line break outside quotes ends the command, so two lines are refused instead of merged")
    func lineBreakEndsTheCommand() {
        #expect(parse("DEL a\nDEL b") == nil)
        #expect(parse("SET k v\r\nGET k") == nil)
        #expect(parse("SET k v\rGET k") == nil)
        #expect(error("DEL a\nDEL b")?.contains("more than one Redis command") == true)
    }

    @Test("leading and trailing line breaks and a closing semicolon add nothing")
    func surroundingSeparators() {
        #expect(parse("\n\r\nGET k\n\n") == ["GET", "k"])
        #expect(parse("GET k;") == ["GET", "k"])
    }

    @Test("a quoted argument keeps its line breaks")
    func quotedKeepsLineBreaks() {
        #expect(parse("SET k \"line1\nline2\"") == ["SET", "k", "line1\nline2"])
        #expect(parse("SET k \"a\r\nb\"") == ["SET", "k", "a\r\nb"])
        #expect(parse("SET k 'a\nb'") == ["SET", "k", "a\nb"])
    }

    @Test("spaces and tabs separate arguments, and quotes keep them")
    func blanks() {
        #expect(parse("  GET\t\tk  ") == ["GET", "k"])
        #expect(parse("SET greeting \"hello world\"") == ["SET", "greeting", "hello world"])
        #expect(parse("SET greeting 'hello world'") == ["SET", "greeting", "hello world"])
    }

    @Test("a backslash outside quotes is part of the argument, as in redis-cli and on the Mac")
    func backslashOutsideQuotes() {
        #expect(parse("DEL victim\\") == ["DEL", "victim\\"])
        #expect(parse("SET k a\\ b") == ["SET", "k", "a\\", "b"])
    }

    @Test("double quotes decode escapes, single quotes only an escaped quote")
    func escapes() {
        #expect(parse("SET k \"say \\\"hi\\\"\"") == ["SET", "k", "say \"hi\""])
        #expect(parse("SET k \"a\\nb\\x41\"") == ["SET", "k", "a\nbA"])
        #expect(parse("SET k 'a\\nb'") == ["SET", "k", "a\\nb"])
        #expect(parse("SET k 'it\\'s'") == ["SET", "k", "it's"])
    }

    @Test("a hex escape sends the raw byte, a NUL and invalid UTF-8 included")
    func rawBytes() throws {
        let arguments = try RedisDriver.commandArguments("SET k \"a\\x00\\xff\"")
        #expect(arguments.last == Data([0x61, 0x00, 0xFF]))
    }

    @Test("an empty quoted argument is kept, so a write receives every value it was given")
    func emptyQuotedArgumentIsKept() {
        #expect(parse("LPUSH l \"\" x") == ["LPUSH", "l", "", "x"])
        #expect(parse("SET k ''") == ["SET", "k", ""])
    }

    @Test("empty and blank input give no command")
    func emptyInput() {
        #expect(parse("") == nil)
        #expect(parse(" \t ") == nil)
        #expect(error("") == "Redis command failed: Empty command")
    }

    @Test("an unclosed quote, or text right after a closing quote, gives no command")
    func unclosedQuoteGivesNil() {
        #expect(parse("SET greeting \"hello") == nil)
        #expect(parse("SET greeting 'hello") == nil)
        #expect(parse("SET k \"a\\\"") == nil)
        #expect(parse("SET k \"a\"b") == nil)
        #expect(error("SET greeting \"hello")?.contains("unbalanced quotes") == true)
    }

    @Test("Run on a command ending in a backslash sends the backslash in its key")
    func trailingBackslashReachesTheDriver() {
        let script = "DEL victim\\ ; GET other"
        let target = QueryRunTarget.resolve(
            in: script, selection: NSRange(location: 2, length: 0), databaseType: .redis, session: nil
        )
        #expect(target == .statement("DEL victim\\", range: NSRange(location: 0, length: 11)))
        for text in ["DEL victim\\ ", script] {
            let runText = QueryScript.trimmed(text, databaseType: .redis)
            let units = QueryScript.plan(runText, databaseType: .redis, sendsBatchesWhole: false).units
            let arguments = units.first.flatMap { parse($0.sql) }
            #expect(arguments == ["DEL", "victim\\"])
        }
    }

    @Test("every command the splitter finds parses on its own")
    func splitterAndDriverAgree() {
        let script = "SET k a\\\nGET k; SET j 'x;\ny'\nDEL \"q\\\"\" "
        let commands = RedisCommandSplitter.commands(in: script)
        #expect(commands.map { parse($0.text) } == [
            ["SET", "k", "a\\"], ["GET", "k"], ["SET", "j", "x;\ny"], ["DEL", "q\""],
        ])
    }
}
