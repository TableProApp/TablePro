import Foundation
import TableProPluginKit
import TableProRedisCore
import Testing

struct RedisKeyBrowsePagingTests {
    private func driver() -> RedisPluginDriver {
        RedisPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: 6_379, username: "", password: "", database: "0"
        ))
    }

    private static func scanReply(cursor: String, keys: [String]) -> RedisReply {
        .array([.string(cursor), .array(keys.map(RedisReply.string))])
    }

    // A key gone by the time it is described has no type, so its row needs no further reads.
    private static func described(_ count: Int) -> [RedisReply] {
        Array(repeating: [RedisReply.status("none"), .integer(-2)], count: count).flatMap { $0 }
    }

    private func browse(_ driver: RedisPluginDriver, _ channel: StubRedisChannel, limit: Int, offset: Int) async throws
        -> PluginQueryResult {
        try await driver.executeOperation(
            try RedisCommandParser.parse("KEYBROWSE LIMIT \(limit) OFFSET \(offset)"), connection: channel, startTime: Date()
        )
    }

    private func scans(_ channel: StubRedisChannel) -> [[String]] {
        channel.sentCommands.filter { $0.first == "SCAN" }
    }

    @Test("The next page continues from the saved cursor instead of scanning from the start again")
    func nextPageContinuesTheScan() async throws {
        let driver = driver()
        let channel = StubRedisChannel(
            [Self.scanReply(cursor: "7", keys: ["c", "a", "b"])] + Self.described(2)
                + [Self.scanReply(cursor: "0", keys: ["e", "d"])] + Self.described(2)
        )

        let first = try await browse(driver, channel, limit: 2, offset: 0)
        #expect(first.rows.map { $0[0] } == [.text("a"), .text("b")])
        #expect(first.statusMessage != nil)

        let second = try await browse(driver, channel, limit: 2, offset: 2)
        #expect(second.rows.map { $0[0] } == [.text("c"), .text("d")])
        #expect(second.statusMessage == nil)
        #expect(scans(channel).map { $0[1] } == ["0", "7"])
    }

    @Test("A page past the old 10,000 key ceiling is reached by walking on")
    func noKeyCeiling() async throws {
        let driver = driver()
        let wide = (0 ..< RedisPluginDriver.maxKeyBrowseScan).map { String(format: "k%05d", $0) }
        let channel = StubRedisChannel(
            [Self.scanReply(cursor: "9", keys: wide), Self.scanReply(cursor: "0", keys: ["z1", "z2"])]
                + Self.described(2)
        )

        let page = try await browse(driver, channel, limit: 2, offset: RedisPluginDriver.maxKeyBrowseScan)
        #expect(page.rows.map { $0[0] } == [.text("z1"), .text("z2")])
        #expect(!page.isTruncated)
    }

    @Test("The page on screen asked for again, as Refresh asks, scans from the start")
    func refreshStartsOver() async throws {
        let driver = driver()
        let channel = StubRedisChannel(
            [Self.scanReply(cursor: "0", keys: ["a", "b", "c", "d"])] + Self.described(2) + Self.described(2)
                + [Self.scanReply(cursor: "0", keys: ["a", "b", "c", "d"])] + Self.described(2)
        )

        _ = try await browse(driver, channel, limit: 2, offset: 0)
        _ = try await browse(driver, channel, limit: 2, offset: 2)
        _ = try await browse(driver, channel, limit: 2, offset: 2)
        #expect(scans(channel).count == 2)
    }

    @Test("A different MATCH pattern is its own walk")
    func filterIsItsOwnWalk() async throws {
        let driver = driver()
        let channel = StubRedisChannel(
            [Self.scanReply(cursor: "5", keys: ["a", "b"])] + Self.described(2)
                + [Self.scanReply(cursor: "0", keys: ["user:1", "user:2", "user:3"])] + Self.described(1)
        )

        _ = try await browse(driver, channel, limit: 2, offset: 0)
        let filtered = try await driver.executeOperation(
            try RedisCommandParser.parse(#"KEYBROWSE MATCH "user:*" LIMIT 2 OFFSET 2"#), connection: channel, startTime: Date()
        )
        #expect(filtered.rows.map { $0[0] } == [.text("user:3")])
        #expect(scans(channel).last?[1] == "0")
    }

    @Test("A browse of every key still starts at its offset")
    func unlimitedBrowseKeepsItsOffset() async throws {
        let channel = StubRedisChannel([Self.scanReply(cursor: "0", keys: ["c", "a", "b"])] + Self.described(2))
        let page = try await browse(driver(), channel, limit: 0, offset: 1)
        #expect(page.rows.map { $0[0] } == [.text("b"), .text("c")])
    }

    @Test("An offset at the end of Int reads to the end of the keyspace instead of overflowing")
    func hugeOffsetDoesNotOverflow() async throws {
        let channel = StubRedisChannel([Self.scanReply(cursor: "0", keys: ["a"])])
        let page = try await browse(driver(), channel, limit: 200, offset: Int.max)
        #expect(page.rows.isEmpty)
    }
}
