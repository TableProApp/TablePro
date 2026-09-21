import Foundation
@testable import TableProMobile
import Testing

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

    @Test("an error reply reads as an error where it is rendered as text")
    func errorStringRepresentation() {
        let reply = RedisReplyValue.error("WRONGTYPE Operation against a key holding the wrong kind of value")
        #expect(reply.stringRepresentation == "(error) WRONGTYPE Operation against a key holding the wrong kind of value")
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
    @Test("a cursor and its elements parse")
    func parsesCursorAndKeys() throws {
        let page = try RedisScanPage(reply: scanReply(cursor: "0", keys: ["b", "a"]), command: "SCAN")
        #expect(page == RedisScanPage(cursor: "0", elements: ["b", "a"]))
    }

    @Test("a status or integer cursor is accepted")
    func acceptsStatusAndIntegerCursors() throws {
        let status = try RedisScanPage(reply: .array([.status("17"), .array([.status("k")])]), command: "SCAN")
        #expect(status == RedisScanPage(cursor: "17", elements: ["k"]))
        let integer = try RedisScanPage(reply: .array([.integer(42), .array([])]), command: "SCAN")
        #expect(integer == RedisScanPage(cursor: "42", elements: []))
    }

    @Test("a reply of any other shape ends the walk with no elements", arguments: [
        RedisReplyValue.null,
        .string("5"),
        .array([.string("5")])
    ])
    func otherShapesEndTheWalk(reply: RedisReplyValue) throws {
        let page = try RedisScanPage(reply: reply, command: "SCAN")
        #expect(page == RedisScanPage(cursor: RedisScanPage.startCursor, elements: []))
    }

    @Test("a refused SCAN throws the server's message", arguments: [
        "NOPERM User limited has no permissions to run the 'scan' command",
        "LOADING Redis is loading the dataset in memory"
    ])
    func refusedScanThrows(message: String) {
        #expect(throws: RedisError.queryFailed(message)) {
            try RedisScanPage(reply: .error(message), command: "SCAN")
        }
    }

    @Test("a queued SCAN throws instead of reading as an empty keyspace")
    func queuedScanThrows() {
        #expect(throws: RedisError.commandQueued("SCAN")) {
            try RedisScanPage(reply: .status("QUEUED"), command: "SCAN")
        }
    }

    @Test("a queued HSCAN names the command it held")
    func queuedCollectionScanNamesItsCommand() {
        #expect(throws: RedisError.commandQueued("HSCAN")) {
            try RedisScanPage(reply: .status("QUEUED"), command: "HSCAN")
        }
    }

    @Test("a key named QUEUED stays a key")
    func keyNamedQueuedIsAKey() throws {
        let page = try RedisScanPage(reply: scanReply(cursor: "0", keys: ["QUEUED"]), command: "SCAN")
        #expect(page.elements == ["QUEUED"])
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

    @Test("a key two pages return is listed once")
    func repeatedKeyIsListedOnce() async throws {
        let server = ScriptedRedisServer(replies: [
            scanReply(cursor: "17", keys: ["a", "b"]),
            scanReply(cursor: "0", keys: ["b", "c"])
        ])
        let keys = try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        #expect(keys == ["a", "b", "c"])
        #expect(await server.sent.count == 2)
    }

    @Test("a key repeated within one page is listed once")
    func repeatedKeyWithinAPageIsListedOnce() async throws {
        let server = ScriptedRedisServer(replies: [scanReply(cursor: "0", keys: ["a", "a", "b"])])
        let keys = try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        #expect(keys == ["a", "b"])
    }

    @Test("distinct keys stop at the key limit")
    func distinctKeysStopAtTheKeyLimit() async throws {
        let pageSize = RedisKeyspaceReads.scanPageSize
        let server = ScriptedRedisServer { page in
            scanReply(cursor: "7", keys: (0 ..< pageSize).map { "key:\(page):\($0)" })
        }
        let keys = try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        #expect(keys.count == RedisKeyspaceReads.keyLimit)
        #expect(Set(keys).count == RedisKeyspaceReads.keyLimit)
        #expect(await server.sent.count == RedisKeyspaceReads.keyLimit / pageSize)
    }

    @Test("a server repeating one page ends at the work limit with each key once")
    func repeatingServerEndsAtTheWorkLimit() async throws {
        let pageKeys = (0 ..< RedisKeyspaceReads.scanPageSize).map { "key:\($0)" }
        let server = ScriptedRedisServer(replies: [scanReply(cursor: "7", keys: pageKeys)], repeatsLastReply: true)
        let keys = try await RedisKeyspaceReads.keys { try await server.reply(to: $0) }
        #expect(keys == pageKeys)
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
