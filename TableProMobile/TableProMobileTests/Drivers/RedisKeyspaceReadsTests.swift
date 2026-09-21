import Foundation
@testable import TableProMobile
import Testing

private actor ScriptedRedisServer {
    private var replies: [RedisReplyValue]
    private let repeatsLastReply: Bool
    private(set) var sent: [[String]] = []

    init(replies: [RedisReplyValue], repeatsLastReply: Bool = false) {
        self.replies = replies
        self.repeatsLastReply = repeatsLastReply
    }

    func reply(to arguments: [String]) throws -> RedisReplyValue {
        sent.append(arguments)
        guard let next = replies.first else { throw ScriptExhausted() }
        if replies.count > 1 || !repeatsLastReply {
            replies.removeFirst()
        }
        return next
    }

    struct ScriptExhausted: Error {}
}

private func scanReply(cursor: String, keys: [String]) -> RedisReplyValue {
    .array([.string(cursor), .array(keys.map { .string($0) })])
}

@Suite("Redis reply guards")
struct RedisReplyValueGuardTests {
    @Test("an error reply throws the server's message")
    func errorReplyThrows() {
        let reply = RedisReplyValue.error("NOPERM User limited has no permissions to run the 'scan' command")
        #expect(throws: RedisError.queryFailed("NOPERM User limited has no permissions to run the 'scan' command")) {
            try reply.throwIfError()
        }
    }

    @Test("a status QUEUED reply throws for the command it held")
    func queuedStatusThrows() {
        #expect(throws: RedisError.commandQueued("SELECT")) {
            try RedisReplyValue.status("QUEUED").throwIfQueued("SELECT")
        }
    }

    /// Measured on Redis 8.10.1: a `GET` of a key holding the word answers the bulk string, which is
    /// a value and not the block's acknowledgement.
    @Test("a bulk string QUEUED is a value")
    func bulkQueuedIsAValue() throws {
        let reply = try RedisReplyValue.string("QUEUED").throwIfError().throwIfQueued("GET")
        #expect(reply == .string("QUEUED"))
        #expect(!RedisReplyValue.string("QUEUED").isQueued)
    }

    @Test("a good reply passes both guards unchanged")
    func goodReplyPasses() throws {
        let reply = try RedisReplyValue.status("OK").throwIfError().throwIfQueued("SELECT")
        #expect(reply == .status("OK"))
    }

    @Test("the queued error names the command and the open block")
    func queuedDescription() {
        #expect(
            RedisError.commandQueued("SCAN").errorDescription
                == "Redis queued SCAN instead of running it. "
                + "A MULTI block is open on this connection. Run EXEC to apply it, or DISCARD to drop it."
        )
    }
}

@Suite("Redis SCAN page")
struct RedisScanPageTests {
    @Test("a cursor and its keys parse")
    func parsesCursorAndKeys() throws {
        let page = try RedisScanPage(reply: scanReply(cursor: "0", keys: ["b", "a"]))
        #expect(page == RedisScanPage(cursor: "0", keys: ["b", "a"]))
    }

    @Test("a status or integer cursor is accepted")
    func acceptsStatusAndIntegerCursors() throws {
        let status = try RedisScanPage(reply: .array([.status("17"), .array([.status("k")])]))
        #expect(status == RedisScanPage(cursor: "17", keys: ["k"]))
        let integer = try RedisScanPage(reply: .array([.integer(42), .array([])]))
        #expect(integer == RedisScanPage(cursor: "42", keys: []))
    }

    @Test("a reply of any other shape ends the walk with no keys", arguments: [
        RedisReplyValue.null,
        .string("5"),
        .array([.string("5")])
    ])
    func otherShapesEndTheWalk(reply: RedisReplyValue) throws {
        let page = try RedisScanPage(reply: reply)
        #expect(page == RedisScanPage(cursor: RedisScanPage.startCursor, keys: []))
    }

    @Test("a refused SCAN throws the server's message", arguments: [
        "NOPERM User limited has no permissions to run the 'scan' command",
        "LOADING Redis is loading the dataset in memory"
    ])
    func refusedScanThrows(message: String) {
        #expect(throws: RedisError.queryFailed(message)) {
            try RedisScanPage(reply: .error(message))
        }
    }

    @Test("a queued SCAN throws instead of reading as an empty keyspace")
    func queuedScanThrows() {
        #expect(throws: RedisError.commandQueued("SCAN")) {
            try RedisScanPage(reply: .status("QUEUED"))
        }
    }

    @Test("a key named QUEUED stays a key")
    func keyNamedQueuedIsAKey() throws {
        let page = try RedisScanPage(reply: scanReply(cursor: "0", keys: ["QUEUED"]))
        #expect(page.keys == ["QUEUED"])
    }
}

@Suite("Redis keyspace reads")
struct RedisKeyspaceReadsTests {
    @Test("the walk follows the cursor and returns every key")
    func walksEveryPage() async throws {
        let server = ScriptedRedisServer(replies: [
            scanReply(cursor: "17", keys: ["b", "a"]),
            scanReply(cursor: "0", keys: ["c"])
        ])
        let keys = try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        #expect(keys == ["b", "a", "c"])
        #expect(await server.sent == [
            ["SCAN", "0", "MATCH", "*", "COUNT", "1000"],
            ["SCAN", "17", "MATCH", "*", "COUNT", "1000"]
        ])
    }

    @Test("a queued first page throws after one SCAN")
    func queuedFirstPageThrows() async {
        let server = ScriptedRedisServer(replies: [.status("QUEUED"), scanReply(cursor: "0", keys: ["a"])])
        await #expect(throws: RedisError.commandQueued("SCAN")) {
            try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        }
        #expect(await server.sent.count == 1)
    }

    @Test("a refused later page throws rather than returning the keys read so far")
    func refusedLaterPageThrows() async {
        let loading = "LOADING Redis is loading the dataset in memory"
        let server = ScriptedRedisServer(replies: [scanReply(cursor: "9", keys: ["a"]), .error(loading)])
        await #expect(throws: RedisError.queryFailed(loading)) {
            try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        }
        #expect(await server.sent.count == 2)
    }

    @Test("the walk stops at the key limit")
    func stopsAtTheKeyLimit() async throws {
        let pageKeys = (0 ..< RedisKeyspaceReads.scanPageSize).map { "key:\($0)" }
        let server = ScriptedRedisServer(replies: [scanReply(cursor: "7", keys: pageKeys)], repeatsLastReply: true)
        let keys = try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        #expect(keys.count == RedisKeyspaceReads.keyLimit)
        #expect(await server.sent.count == RedisKeyspaceReads.keyLimit / RedisKeyspaceReads.scanPageSize)
    }

    @Test("a key's type is read from a status or bulk reply")
    func typeName() async throws {
        let cases: [(reply: RedisReplyValue, expected: String)] = [
            (.status("hash"), "hash"),
            (.string("zset"), "zset"),
            (.null, "unknown")
        ]
        for testCase in cases {
            let server = ScriptedRedisServer(replies: [testCase.reply])
            let name = try await RedisKeyspaceReads.typeName(ofKey: "k1") { try await server.reply(to: $0) }
            #expect(name == testCase.expected, "\(testCase.reply)")
            #expect(await server.sent == [["TYPE", "k1"]])
        }
    }

    @Test("a refused TYPE throws the server's message")
    func refusedTypeThrows() async {
        let noperm = "NOPERM User notype has no permissions to run the 'type' command"
        let server = ScriptedRedisServer(replies: [.error(noperm)])
        await #expect(throws: RedisError.queryFailed(noperm)) {
            try await RedisKeyspaceReads.typeName(ofKey: "k1") { try await server.reply(to: $0) }
        }
    }

    @Test("a queued TYPE throws instead of naming the type QUEUED")
    func queuedTypeThrows() async {
        let server = ScriptedRedisServer(replies: [.status("QUEUED")])
        await #expect(throws: RedisError.commandQueued("TYPE")) {
            try await RedisKeyspaceReads.typeName(ofKey: "k1") { try await server.reply(to: $0) }
        }
    }
}
