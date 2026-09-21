import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Redis key browse")
struct RedisKeyBrowseTests {
    private func browse(
        _ replies: [RedisReplyValue],
        key: String = "k",
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> (page: KeyContentsPage, sent: [[String]]) {
        let server = ScriptedRedisServer(replies: replies)
        let page = try await RedisKeyBrowse.page(ofKey: key, limit: limit, offset: offset) {
            try await server.reply(to: $0)
        }
        return (page, await server.sent)
    }

    private func sentBeforeFailing(_ replies: [RedisReplyValue], expecting error: RedisError) async -> [[String]] {
        let server = ScriptedRedisServer(replies: replies)
        await #expect(throws: error) {
            try await RedisKeyBrowse.page(ofKey: "k", limit: 100, offset: 0) { try await server.reply(to: $0) }
        }
        return await server.sent
    }

    @Test("a string key is read with GET and counts as one row")
    func stringKey() async throws {
        let (page, sent) = try await browse([.status("string"), .string("hello")])
        #expect(sent == [["TYPE", "k"], ["GET", "k"]])
        #expect(page.result.columns.map(\.name) == ["value"])
        #expect(page.result.rows == [["hello"]])
        #expect(page.totalCount == 1)
    }

    @Test("a string key past its first page reads nothing more")
    func stringKeyPastFirstPage() async throws {
        let (page, sent) = try await browse([.status("string")], offset: 100)
        #expect(sent == [["TYPE", "k"]])
        #expect(page.result.rows.isEmpty)
        #expect(page.totalCount == 1)
    }

    @Test("a string key deleted after its TYPE was read is reported gone")
    func stringKeyGoneBeforeGet() async {
        let sent = await sentBeforeFailing([.status("string"), .null], expecting: .keyNotFound("k"))
        #expect(sent == [["TYPE", "k"], ["GET", "k"]])
    }

    @Test("a list page is an exact range whose index counts from the offset")
    func listPage() async throws {
        let (page, sent) = try await browse(
            [.status("list"), .integer(250), .array([.string("e100"), .string("e101")])],
            offset: 100
        )
        #expect(sent == [["TYPE", "k"], ["LLEN", "k"], ["LRANGE", "k", "100", "199"]])
        #expect(page.result.columns.map(\.name) == ["index", "element"])
        #expect(page.result.rows == [["100", "e100"], ["101", "e101"]])
        #expect(page.totalCount == 250)
    }

    @Test("a sorted set page pairs each member with its score")
    func sortedSetPage() async throws {
        let (page, sent) = try await browse(
            [.status("zset"), .integer(2), .array([.string("a"), .string("1"), .string("b"), .string("2.5")])],
            limit: 2
        )
        #expect(sent == [["TYPE", "k"], ["ZCARD", "k"], ["ZRANGE", "k", "0", "1", "WITHSCORES"]])
        #expect(page.result.columns.map(\.name) == ["member", "score"])
        #expect(page.result.rows == [["a", "1"], ["b", "2.5"]])
    }

    @Test("a hash field two HSCAN pages return is listed once")
    func hashFieldRepeatedAcrossPages() async throws {
        let (page, sent) = try await browse([
            .status("hash"),
            .integer(2),
            scanReply(cursor: "5", keys: ["name", "ada"]),
            scanReply(cursor: "0", keys: ["name", "ada", "age", "36"])
        ])
        #expect(sent == [
            ["TYPE", "k"],
            ["HLEN", "k"],
            ["HSCAN", "k", "0", "COUNT", "1000"],
            ["HSCAN", "k", "5", "COUNT", "1000"]
        ])
        #expect(page.result.columns.map(\.name) == ["field", "value"])
        #expect(page.result.rows == [["name", "ada"], ["age", "36"]])
        #expect(page.totalCount == 2)
    }

    @Test("a hash walk stops once the page is covered and slices it out")
    func hashWalkStopsAtThePage() async throws {
        let (page, sent) = try await browse(
            [.status("hash"), .integer(40), scanReply(cursor: "5", keys: ["name", "ada", "age", "36"])],
            limit: 1,
            offset: 1
        )
        #expect(sent.filter { $0.first == "HSCAN" }.count == 1)
        #expect(page.result.rows == [["age", "36"]])
    }

    @Test("a set member two SSCAN pages return is listed once")
    func setMemberRepeatedAcrossPages() async throws {
        let (page, sent) = try await browse([
            .status("set"),
            .integer(3),
            scanReply(cursor: "3", keys: ["x", "y"]),
            scanReply(cursor: "0", keys: ["y", "z"])
        ])
        #expect(sent.last == ["SSCAN", "k", "3", "COUNT", "1000"])
        #expect(page.result.columns.map(\.name) == ["member"])
        #expect(page.result.rows == [["x"], ["y"], ["z"]])
    }

    @Test("a set page past the end of the set is empty")
    func setPagePastTheEnd() async throws {
        let (page, _) = try await browse(
            [.status("set"), .integer(1), scanReply(cursor: "0", keys: ["x"])],
            offset: 100
        )
        #expect(page.result.rows.isEmpty)
    }

    @Test("a stream page skips the entries before its offset and reads fields as JSON")
    func streamPage() async throws {
        let entry: (String, [String]) -> RedisReplyValue = { id, fields in
            .array([.string(id), .array(fields.map { .string($0) })])
        }
        let (page, sent) = try await browse(
            [
                .status("stream"),
                .integer(3),
                .array([
                    entry("1-0", ["name", "bob"]),
                    entry("2-0", ["name", "ada", "age", "36"]),
                    entry("3-0", ["name", "cy"])
                ])
            ],
            limit: 2,
            offset: 1
        )
        #expect(sent == [["TYPE", "k"], ["XLEN", "k"], ["XRANGE", "k", "-", "+", "COUNT", "3"]])
        #expect(page.result.columns.map(\.name) == ["id", "fields"])
        #expect(page.result.rows == [["2-0", #"{"age":"36","name":"ada"}"#], ["3-0", #"{"name":"cy"}"#]])
    }

    @Test("a key that no longer exists is reported by name")
    func missingKey() async {
        let sent = await sentBeforeFailing([.status("none")], expecting: .keyNotFound("k"))
        #expect(sent == [["TYPE", "k"]])
    }

    @Test("a key of a type the browser cannot read is refused by type")
    func unbrowsableType() async {
        let sent = await sentBeforeFailing([.status("vectorset")], expecting: .keyTypeNotBrowsable("vectorset"))
        #expect(sent == [["TYPE", "k"]])
    }

    @Test("a refused read throws the server's message")
    func refusedRead() async {
        let noperm = "NOPERM No permissions to access a key"
        _ = await sentBeforeFailing([.status("string"), .error(noperm)], expecting: .queryFailed(noperm))
    }

    @Test("a refused length throws the server's message")
    func refusedLength() async {
        let noperm = "NOPERM User limited has no permissions to run the 'llen' command"
        let sent = await sentBeforeFailing([.status("list"), .error(noperm)], expecting: .queryFailed(noperm))
        #expect(sent == [["TYPE", "k"], ["LLEN", "k"]])
    }

    @Test("a queued TYPE throws instead of naming the type QUEUED")
    func queuedType() async {
        _ = await sentBeforeFailing([.status("QUEUED")], expecting: .commandQueued("TYPE"))
    }

    @Test("a queued range read names the command it held")
    func queuedRange() async {
        _ = await sentBeforeFailing(
            [.status("list"), .integer(3), .status("QUEUED")],
            expecting: .commandQueued("LRANGE")
        )
    }

    @Test("no kind reads a primary key, so no page can be edited as a row")
    func noKindHasAPrimaryKey() {
        for kind in RedisKeyKind.allCases {
            let primaryKeys = RedisKeyBrowse.columns(for: kind).filter(\.isPrimaryKey)
            #expect(primaryKeys.isEmpty, "\(kind)")
        }
    }
}
