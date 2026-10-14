//
//  RedisKeyTreeCommandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProRedisCore
import Testing

// The Redis plugin splits a command with the same RedisArgumentCodec, and RedisDriverTests'
// RedisKeyTreeAppCommandParseTests holds it to reading these commands as the reads they mean.
struct RedisKeyTreeAppCommandTests {
    @Test("The tree's listing names its database and its limit")
    func listingRoundTrips() {
        let command = RedisKeyTreeCommand.listKeys(inDatabase: 7, limit: 50_000)
        #expect(command == "KEYTREE DB 7 LIMIT 50000")
        #expect(RedisArgumentCodec.split(command) == ["KEYTREE", "DB", "7", "LIMIT", "50000"].map { Data($0.utf8) })
    }

    static let keys = [
        "zero:a",
        "has space",
        #"back\slash"#,
        #"trailing\"#,
        #"quote"d"#,
        "it's",
        "new\nline",
        "tab\there",
        #"\x41 stays text"#,
        "semi;colon",
        "café ☕",
        "bell\u{07}and\u{7F}"
    ]

    private static let reads: [(keyType: String?, verb: [String], trailing: [String])] = [
        ("string", ["GET"], []),
        ("hash", ["HGETALL"], []),
        ("list", ["LRANGE"], ["0", "-1"]),
        ("set", ["SMEMBERS"], []),
        ("zset", ["ZRANGE"], ["0", "-1", "WITHSCORES"]),
        ("STREAM", ["XRANGE"], ["-", "+"]),
        (nil, ["GET"], [])
    ]

    @Test("Opening a key reads exactly that key, whatever it holds", arguments: keys)
    func openedKeyRoundTrips(key: String) throws {
        for read in Self.reads {
            let command = RedisKeyTreeCommand.openKey(key, keyType: read.keyType, inDatabase: 4)
            let split = try #require(RedisArgumentCodec.split(command), "\(command)")
            let expected = [Data("DB".utf8), Data("4".utf8)] + read.verb.map { Data($0.utf8) }
                + [Data(key.utf8)] + read.trailing.map { Data($0.utf8) }
            #expect(split == expected, "\(read.keyType ?? "nil"): \(command)")
        }
    }
}
