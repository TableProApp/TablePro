//
//  RedisQueuedReplyTests.swift
//  TableProTests
//
//  A command sent while a MULTI block is open answers `+QUEUED` rather than its own reply, and
//  every caller that read a value out of one read the acknowledgement instead: GET returned
//  "QUEUED" as the stored value, DEL counted zero deletions, LPUSH reported length zero and the
//  sidebar's DBSIZE reported an empty keyspace.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Redis reply - a queued acknowledgement is not an answer")
struct RedisQueuedReplyShapeTests {
    @Test("A +QUEUED simple string is the acknowledgement")
    func statusIsQueued() {
        #expect(RedisReply.status("QUEUED").isQueued)
    }

    /// The shape carries the signal, not the text. Measured over raw RESP on Redis 8.10.1: a
    /// queued command answers `+QUEUED\r\n`, while a GET of a key holding the word answers the
    /// bulk string `$6\r\nQUEUED`.
    static let notQueued: [RedisReply] = [
        .string("QUEUED"),
        .data(Data("QUEUED".utf8)),
        .error("QUEUED"),
        .status("queued"),
        .status("QUEUED "),
        .status("OK"),
        .status(""),
        .integer(1),
        .array([.status("QUEUED")]),
        .null,
    ]

    @Test("Every other reply carrying the same word is a value", arguments: notQueued)
    func otherShapesAreValues(reply: RedisReply) {
        #expect(!reply.isQueued)
    }

    @Test("throwIfQueued names the command that was queued")
    func throwIfQueuedNamesTheCommand() throws {
        do {
            try RedisReply.status("QUEUED").throwIfQueued("DBSIZE")
            Issue.record("expected a throw")
        } catch let queued as RedisQueuedCommand {
            #expect(queued == RedisQueuedCommand(command: "DBSIZE"))
            #expect(queued.pluginErrorMessage.contains("DBSIZE"))
            #expect(queued.pluginErrorDetail?.isEmpty == false)
        }
    }

    @Test("A real reply passes straight through")
    func passesThroughValues() throws {
        #expect(try RedisReply.string("QUEUED").throwIfQueued("GET").stringValue == "QUEUED")
        #expect(try RedisReply.integer(3).throwIfQueued("DEL").intValue == 3)
    }

    @Test("A command with no name still reports something readable")
    func unnamedCommand() {
        #expect(RedisQueuedCommand(command: "").pluginErrorMessage.isEmpty == false)
    }
}

@Suite("Redis command channel - the run choke point")
struct RedisCommandChannelRunTests {
    @Test("run(_: [String]) refuses a queued acknowledgement")
    func stringOverloadRefusesQueued() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        await #expect(throws: RedisQueuedCommand(command: "GET")) {
            try await channel.run(["GET", "k"])
        }
    }

    @Test("run(_: [Data]) refuses a queued acknowledgement and decodes the command name")
    func dataOverloadRefusesQueued() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        await #expect(throws: RedisQueuedCommand(command: "DEL")) {
            try await channel.run([Data("DEL".utf8), Data("k".utf8)])
        }
    }

    /// A server error is still the first thing checked, so a refusal inside a block is reported as
    /// the refusal it is rather than as the queueing that never happened.
    @Test("An error reply throws the driver error, not the queued one")
    func errorBeatsQueued() async throws {
        let channel = StubRedisChannel([.error("NOPERM User lim has no permissions to run the 'expire' command")])
        do {
            try await channel.run(["EXPIRE", "k", "10"])
            Issue.record("expected a throw")
        } catch let error as RedisPluginError {
            #expect(error.message.contains("NOPERM"))
        }
    }

    @Test("A real reply is returned unchanged by both overloads")
    func realRepliesPassThrough() async throws {
        let strings = StubRedisChannel([.integer(2)])
        #expect(try await strings.run(["DEL", "a", "b"]).intValue == 2)

        let datas = StubRedisChannel([.string("hello")])
        #expect(try await datas.run([Data("GET".utf8), Data("s".utf8)]).stringValue == "hello")
    }
}

@Suite("Redis queued command policy")
struct RedisQueuedCommandPolicyTests {
    /// A one-row `QUEUED` status in the data grid reads as an empty table, so the two walks the app
    /// builds for itself say the keyspace could not be read instead.
    @Test("The app's own keyspace walks refuse a queued reply")
    func appKeyspaceWalksRefuse() {
        #expect(RedisOperation.keyBrowse(pattern: nil, typeScope: nil, limit: 100, offset: 0)
            .queuedCommandAnswer == .refuse)
        #expect(RedisOperation.keyTree(pattern: nil, limit: 100).queuedCommandAnswer == .refuse)
    }

    @Test("A command the user typed reports the acknowledgement the server gave it")
    func userCommandsReportQueued() {
        let operations: [RedisOperation] = [
            .get(key: "k"),
            .set(key: "k", value: Data("v".utf8), options: nil),
            .del(keys: ["k"]),
            .dbsize,
            .exists(keys: ["k"]),
        ]
        for operation in operations {
            #expect(operation.queuedCommandAnswer == .reportQueued)
        }
    }
}

/// The paged read and the streamed read both run an operation, and the streamed one used to run it
/// without translating the queued reply: a command sent into the user's open block threw instead of
/// answering `QUEUED`, and nothing recorded it, so `EXEC`'s replies paired with the recorded commands
/// one position out. The translation therefore belongs to the one function that dispatches an
/// operation, not to a route. The plugin imports CRedis, which this target cannot, so the guard is a
/// source scan.
@Suite("Redis queued translation source scan")
struct RedisQueuedTranslationSourceScanTests {
    private static let pluginDirectory: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { directory.deleteLastPathComponent() }
        return directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("RedisDriverPlugin")
    }()

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: pluginDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private static let queuedCatch = "catch let queued as RedisQueuedCommand"

    @Test("The operation dispatcher is what translates a queued reply")
    func theDispatcherTranslates() throws {
        #expect(try Self.source("RedisPluginDriver+Operations.swift").contains(Self.queuedCatch))
    }

    @Test("No route translates a queued reply for itself")
    func noRouteTranslatesOnItsOwn() throws {
        #expect(!(try Self.source("RedisPluginDriver.swift").contains(Self.queuedCatch)))
    }
}

@Suite("Redis command channel - the default keyspace walk")
struct RedisCommandChannelScanTests {
    @Test("A queued SCAN is refused rather than read as an empty keyspace")
    func queuedScanIsRefused() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        await #expect(throws: RedisQueuedCommand(command: "SCAN")) {
            try await channel.scanKeyspace(cursor: "0", pattern: nil, type: nil, count: 200)
        }
    }

    @Test("A refused SCAN throws the server's error")
    func erroredScanThrows() async throws {
        let channel = StubRedisChannel([.error("NOPERM no permissions to run the 'scan' command")])
        await #expect(throws: RedisPluginError.self) {
            try await channel.scanKeyspace(cursor: "0", pattern: nil, type: nil, count: 200)
        }
    }

    @Test("A real SCAN answer is parsed into a page")
    func realScanIsParsed() async throws {
        let channel = StubRedisChannel([
            .array([.string("17"), .array([.string("a"), .string("b")])]),
        ])
        let page = try await channel.scanKeyspace(cursor: "0", pattern: "*", type: "string", count: 200)
        #expect(page.cursor == "17")
        #expect(page.keys == ["a", "b"])
        #expect(!page.isIncomplete)
        #expect(!page.isFinished)
        #expect(channel.sentCommands == [["SCAN", "0", "MATCH", "*", "COUNT", "200", "TYPE", "string"]])
    }
}
