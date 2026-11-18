import Foundation
import TableProPluginKit
import TableProRedisCore
import Testing

struct RedisKeyScanCountTests {
    private func driver() -> RedisPluginDriver {
        RedisPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: 6_379, username: "", password: "", database: "0"
        ))
    }

    private static func scanReply(cursor: String, keys: [String]) -> RedisReply {
        .array([.string(cursor), .array(keys.map(RedisReply.string))])
    }

    private func sentCount(_ command: [String]) -> String? {
        command.firstIndex(of: "COUNT").map { command[$0 + 1] }
    }

    @Test("A browse reads the whole 10,000 key cap in one SCAN")
    func browseCapIsOneCall() async throws {
        let keys = (0 ..< RedisPluginDriver.maxKeyBrowseScan).map { "key:\($0)" }
        let channel = StubRedisChannel([Self.scanReply(cursor: "42", keys: keys)])

        let scanned = try await driver().scanAllKeys(
            connection: channel, pattern: nil, maxKeys: RedisPluginDriver.maxKeyBrowseScan
        )

        #expect(scanned.count == RedisPluginDriver.maxKeyBrowseScan)
        #expect(channel.sentCommands.count == 1)
        #expect(channel.sentCommands.first.flatMap(sentCount) == "10000")
    }

    @Test("A small sample does not ask the server for more than it did", arguments: [1, 100, 1_000])
    func smallSampleKeepsTheNarrowCount(maxKeys: Int) async throws {
        let channel = StubRedisChannel([Self.scanReply(cursor: "0", keys: ["a"])])

        _ = try await driver().scanAllKeys(connection: channel, pattern: nil, maxKeys: maxKeys)

        #expect(channel.sentCommands.first.flatMap(sentCount) == "1000")
    }

    @Test("The count follows the keys wanted between the two bounds")
    func countFollowsTheKeysWanted() {
        #expect(RedisPluginDriver.scanCount(forKeysWanted: 5_000) == 5_000)
    }

    @Test("A key tree wider than the cap holds the server no longer per call")
    func wideKeyTreeStaysAtTheCap() {
        #expect(RedisPluginDriver.scanCount(forKeysWanted: 500_000) == 10_000)
    }

    @Test("A scan the first call did not finish carries on from its cursor")
    func unfinishedScanContinues() async throws {
        let channel = StubRedisChannel([
            Self.scanReply(cursor: "7", keys: ["b"]),
            Self.scanReply(cursor: "0", keys: ["a"]),
        ])

        let scanned = try await driver().scanAllKeys(connection: channel, pattern: "*", maxKeys: 10_000)

        #expect(scanned == ["a", "b"])
        #expect(channel.sentCommands.map { $0[1] } == ["0", "7"])
    }
}
