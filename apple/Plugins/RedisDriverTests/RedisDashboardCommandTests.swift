//
//  RedisDashboardCommandTests.swift
//  TableProTests
//
//  The Server Dashboard reads SLOWLOG GET as a grid and sends every command as OUTSIDEBLOCK, so a
//  refresh is held back while the user has a MULTI block open instead of joining it.
//

import Foundation
import TableProPluginKit
import TableProRedisCore
import Testing

struct RedisSlowLogParseTests {
    @Test("SLOWLOG GET, with or without a count, is typed", arguments: [
        ("SLOWLOG GET", nil),
        ("slowlog get 20", 20),
    ] as [(String, Int?)])
    func slowLogGetIsTyped(statement: String, count: Int?) throws {
        guard case .slowlogGet(let parsed) = try RedisCommandParser.parse(statement) else {
            Issue.record("Expected .slowlogGet for \(statement)")
            return
        }
        #expect(parsed == count)
    }

    @Test("Any other SLOWLOG form goes to the server as typed", arguments: [
        "SLOWLOG LEN", "SLOWLOG RESET", "SLOWLOG GET abc", "SLOWLOG GET 1 2", "SLOWLOG",
    ])
    func otherFormsAreVerbatim(statement: String) throws {
        guard case .command = try RedisCommandParser.parse(statement) else {
            Issue.record("Expected .command for \(statement)")
            return
        }
    }
}

struct RedisOutsideBlockParseTests {
    @Test("OUTSIDEBLOCK keeps the grid of INFO and SLOWLOG GET")
    func keepsTypedServerGrids() throws {
        guard case .outsideBlock(.info(let sections)) = try RedisCommandParser.parse("OUTSIDEBLOCK INFO") else {
            Issue.record("Expected INFO outside the block")
            return
        }
        #expect(sections.isEmpty)
        guard case .outsideBlock(.slowlogGet(let count)) = try RedisCommandParser.parse("OUTSIDEBLOCK SLOWLOG GET 20") else {
            Issue.record("Expected SLOWLOG GET outside the block")
            return
        }
        #expect(count == 20)
    }

    @Test("Any other command is sent as typed", arguments: [
        "OUTSIDEBLOCK CLIENT LIST", "OUTSIDEBLOCK CLIENT KILL ID 21", "outsideblock GET key",
    ])
    func otherCommandsAreVerbatim(statement: String) throws {
        guard case .outsideBlock(.command(let args)) = try RedisCommandParser.parse(statement) else {
            Issue.record("Expected a verbatim command outside the block for \(statement)")
            return
        }
        #expect(args.map { $0.text } == Array(statement.split(separator: " ").dropFirst().map(String.init)))
    }

    @Test("OUTSIDEBLOCK with nothing after it is refused")
    func emptyIsRefused() {
        #expect(throws: RedisParseError.self) { try RedisCommandParser.parse("OUTSIDEBLOCK") }
    }
}

struct RedisSlowLogGridTests {
    @Test("An entry becomes one row, its arguments quoted the way the console reads them")
    func entryBecomesARow() {
        let reply = RedisReply.array([
            .array([
                .integer(9), .integer(1_792_537_207), .integer(626),
                .array([.string("SET"), .string("foo"), .string("a b,c]")]),
                .string("127.0.0.1:59713"), .string("worker"), .integer(3),
            ]),
        ])
        let grid = RedisReplyGrid.slowLog(reply)
        #expect(grid.columns == RedisSlowLogGrid.columns)
        #expect(grid.columnTypeNames.count == grid.columns.count)
        #expect(grid.rows == [[
            .text("9"), .text("1792537207"), .text("626"), .text(#"SET foo "a b,c]""#),
            .text("127.0.0.1:59713"), .text("worker"),
        ]])
    }

    @Test("Redis before 4.0 sends no client, and a malformed entry is skipped")
    func olderAndMalformedEntries() {
        let reply = RedisReply.array([
            .array([.integer(1), .integer(1_500_000_000), .integer(20_000), .array([.string("KEYS"), .string("*")])]),
            .array([.integer(2)]),
            .string("not an entry"),
        ])
        #expect(RedisReplyGrid.slowLog(reply).rows == [[
            .text("1"), .text("1500000000"), .text("20000"), .text("KEYS *"), .null, .null,
        ]])
    }
}

struct RedisOutsideBlockExecutionTests {
    private func driver() -> RedisPluginDriver {
        RedisPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: 6_379, username: "", password: "", database: "0"
        ))
    }

    @Test("A dashboard command runs outside the block scope")
    func runsOutsideTheBlock() async throws {
        let channel = StubRedisChannel([.string("id=21 addr=10.0.0.4:51022 cmd=get")])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("OUTSIDEBLOCK CLIENT LIST"), connection: channel, startTime: Date()
        )
        #expect(channel.sentCommands == [["CLIENT", "LIST"]])
        #expect(channel.sentScopes == [.outsideBlock])
        #expect(result.rows.first?.first?.asText?.hasPrefix("id=21") == true)
    }

    @Test("With the user's MULTI block open the command is held back, never queued into it")
    func heldBackWhileTheBlockIsOpen() async throws {
        let channel = StubRedisChannel([])
        channel.observeOpenBlock()
        await #expect(throws: RedisHeldBackCommand(command: "INFO", held: .openBlock)) {
            _ = try await driver().executeOperation(
                try RedisCommandParser.parse("OUTSIDEBLOCK INFO"), connection: channel, startTime: Date()
            )
        }
        #expect(channel.sentCommands.isEmpty)
    }

    @Test("The same command typed by the user still joins the user's block")
    func typedCommandStillQueues() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        channel.observeOpenBlock()
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("SLOWLOG GET 5"), connection: channel, startTime: Date()
        )
        #expect(channel.sentScopes == [.session])
        #expect(result.rows.first?.first?.asText == "QUEUED")
    }
}
