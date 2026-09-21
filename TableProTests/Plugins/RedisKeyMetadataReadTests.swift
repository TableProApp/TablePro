//
//  RedisKeyMetadataReadTests.swift
//  TableProTests
//
//  The key grid and the key tree read TYPE, TTL and a length and preview probe for every key
//  they list, and read each reply without asking whether the server answered. A refusal came back
//  as an ordinary error reply, so a key an ACL user may not read showed as type UNKNOWN, TTL -1
//  (no expiry) and an empty "{}" collection. The replies here are the ones redis-server 8.10.1
//  sends to users restricted to `~app:*`, without `+type`, without `@hash`, and write-only `%W~*`.
//

import Foundation
import TableProPluginKit
import Testing

private struct TransportFailure: Error, Equatable {}

private let keyDenied = RedisReply.error("NOPERM No permissions to access a key")
private let typeDenied = RedisReply.error("NOPERM User notype has no permissions to run the 'type' command")

@Suite("Redis metadata read - classifying one reply")
struct RedisMetadataReadAnswerTests {
    static let declined: [RedisReply] = [
        keyDenied,
        typeDenied,
        .error("ERR unknown command 'TYPE', with args beginning with: 'k' "),
    ]

    @Test("A key-level or command-level refusal is no answer", arguments: declined)
    func declinedIsNil(reply: RedisReply) throws {
        #expect(try RedisMetadataRead.answer(reply, to: "TYPE") == nil)
    }

    static let surfaced: [String] = [
        "BUSY Redis is busy running a script. You can only call SCRIPT KILL or FUNCTION KILL.",
        "LOADING Redis is loading the dataset in memory",
        "WRONGTYPE Operation against a key holding the wrong kind of value",
    ]

    @Test("Every other error throws, labelled with the command", arguments: surfaced)
    func otherErrorsThrow(message: String) {
        do {
            _ = try RedisMetadataRead.answer(.error(message), to: "TYPE")
            Issue.record("expected a throw")
        } catch let error as RedisPluginError {
            #expect(error.message == "TYPE: \(message)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("A queued acknowledgement throws rather than reading as a type")
    func queuedThrows() {
        #expect(throws: RedisQueuedCommand(command: "TYPE")) {
            try RedisMetadataRead.answer(.status("QUEUED"), to: "TYPE")
        }
    }

    @Test("An answer passes through unchanged")
    func answerPassesThrough() throws {
        #expect(try RedisMetadataRead.answer(.status("hash"), to: "TYPE")?.stringValue == "hash")
        #expect(try RedisMetadataRead.answer(.integer(-1), to: "TTL")?.intValue == -1)
    }
}

@Suite("Redis metadata reads - one pipeline")
struct RedisMetadataReadsPipelineTests {
    @Test("A refusal stays in its own place and the keys around it answer")
    func refusalStaysInPlace() async throws {
        let channel = StubRedisChannel([.status("string"), keyDenied, .status("hash")])
        let answers = try await channel.runMetadataReads([["TYPE", "app:1"], ["TYPE", "other:1"], ["TYPE", "app:h"]])
        #expect(answers.map { $0?.stringValue } == ["string", nil, "hash"])
        #expect(channel.sentScopes == [.outsideBlock, .outsideBlock, .outsideBlock])
    }

    @Test("Nothing is sent for no commands")
    func emptySendsNothing() async throws {
        let channel = StubRedisChannel([])
        #expect(try await channel.runMetadataReads([]).isEmpty)
        #expect(channel.sentCommands.isEmpty)
    }

    @Test("An open MULTI block holds the reads back instead of queueing them")
    func openBlockHoldsBack() async throws {
        let channel = StubRedisChannel([])
        channel.observeOpenBlock()
        await #expect(throws: RedisHeldBackCommand(command: "TYPE", held: .openBlock)) {
            try await channel.runMetadataReads([["TYPE", "k"]])
        }
        #expect(channel.sentCommands.isEmpty)
    }
}

@Suite("Redis key descriptions - TYPE and TTL")
struct RedisKeyDescriptionReadTests {
    @Test("A key the user may not read has no type and no TTL, not UNKNOWN and -1")
    func unreadableKeyIsUnknown() async throws {
        let channel = StubRedisChannel([.status("hash"), .integer(500), keyDenied, keyDenied])
        let descriptions = try await channel.describeKeys(["app:h", "other:1"])

        #expect(descriptions == [
            RedisKeyDescription(typeName: "hash", ttlSeconds: 500),
            RedisKeyDescription(typeName: nil, ttlSeconds: nil),
        ])
        #expect(descriptions[0].typeCell == .text("HASH"))
        #expect(descriptions[0].ttlCell == .text("500"))
        #expect(descriptions[1].typeCell == .null)
        #expect(descriptions[1].ttlCell == .null)
        #expect(channel.sentCommands == [["TYPE", "app:h"], ["TTL", "app:h"], ["TYPE", "other:1"], ["TTL", "other:1"]])
    }

    /// Measured: a user without `+type` is refused TYPE for every key and still answered TTL.
    @Test("A refused TYPE leaves the TTL the server did give")
    func typeAndTtlAreIndependent() async throws {
        let channel = StubRedisChannel([typeDenied, .integer(1_000)])
        let descriptions = try await channel.describeKeys(["other:1"])
        #expect(descriptions == [RedisKeyDescription(typeName: nil, ttlSeconds: 1_000)])
        #expect(descriptions[0].kind == nil)
    }

    @Test("A key with no expiry still reads -1")
    func noExpiryIsMinusOne() async throws {
        let channel = StubRedisChannel([.status("string"), .integer(-1)])
        let descriptions = try await channel.describeKeys(["app:1"])
        #expect(descriptions[0].ttlCell == .text("-1"))
        #expect(descriptions[0].kind == .string)
    }

    @Test("A busy server fails the page")
    func busyThrows() async throws {
        let channel = StubRedisChannel([.error("BUSY Redis is busy running a script."), .integer(-1)])
        do {
            _ = try await channel.describeKeys(["app:1"])
            Issue.record("expected a throw")
        } catch let error as RedisPluginError {
            #expect(error.message == "TYPE: BUSY Redis is busy running a script.")
        }
    }

    @Test("A queued TYPE throws instead of reading as type QUEUED")
    func queuedThrows() async throws {
        let channel = StubRedisChannel([.status("QUEUED"), .status("QUEUED")])
        await #expect(throws: RedisQueuedCommand(command: "TYPE")) {
            try await channel.describeKeys(["app:1"])
        }
    }

    @Test("A dropped connection propagates untouched")
    func transportFailurePropagates() async throws {
        let channel = StubRedisChannel(outcomes: [.failure(TransportFailure())])
        await #expect(throws: TransportFailure()) {
            try await channel.describeKeys(["app:1"])
        }
    }

    @Test("No keys sends nothing")
    func emptySendsNothing() async throws {
        let channel = StubRedisChannel([])
        #expect(try await channel.describeKeys([]).isEmpty)
        #expect(channel.sentCommands.isEmpty)
    }
}

@Suite("Redis key contents - length and preview")
struct RedisKeyContentsReadTests {
    @Test("A key of unknown type gets no probe at all")
    func unknownKindSendsNoProbe() async throws {
        let channel = StubRedisChannel([])
        let contents = try await channel.readContents(
            of: ["other:1"],
            describedAs: [RedisKeyDescription(typeName: nil, ttlSeconds: nil)]
        )
        #expect(contents.count == 1)
        #expect(contents[0] == nil)
        #expect(channel.sentCommands.isEmpty)
    }

    /// Measured: a user without `@hash` reads TYPE `hash` and is refused both HLEN and HSCAN; a
    /// write-only `%W~*` user is answered HLEN and refused HSCAN. The refused scan used to render
    /// as `{}`, an empty hash.
    @Test("A refused preview is no preview, not an empty collection")
    func refusedPreviewIsNil() async throws {
        let channel = StubRedisChannel([.integer(1), keyDenied])
        let contents = try await channel.readContents(
            of: ["app:h"],
            describedAs: [RedisKeyDescription(typeName: "hash", ttlSeconds: -1)]
        )
        let hash = try #require(contents[0])
        #expect(hash.kind == .hash)
        #expect(hash.length == 1)
        #expect(hash.lengthCell == .text("1"))
        #expect(hash.preview == nil)
        #expect(channel.sentCommands == [["HLEN", "app:h"], ["HSCAN", "app:h", "0", "COUNT", "100"]])
    }

    @Test("A refused GET leaves the string length the server gave")
    func refusedGetKeepsLength() async throws {
        let channel = StubRedisChannel([.integer(1), keyDenied])
        let contents = try await channel.readContents(
            of: ["app:1"],
            describedAs: [RedisKeyDescription(typeName: "string", ttlSeconds: nil)]
        )
        let string = try #require(contents[0])
        #expect(string.length == 1)
        #expect(string.preview == nil)
    }

    @Test("Probes line up with their keys when unknown keys sit between them")
    func probesLineUpAroundUnknownKeys() async throws {
        let channel = StubRedisChannel([.integer(3), .string("abc"), .integer(2), .array([.string("x"), .string("y")])])
        let contents = try await channel.readContents(
            of: ["a", "b", "c"],
            describedAs: [
                RedisKeyDescription(typeName: "string", ttlSeconds: -1),
                RedisKeyDescription(typeName: nil, ttlSeconds: nil),
                RedisKeyDescription(typeName: "list", ttlSeconds: -1),
            ]
        )
        #expect(contents.count == 3)
        #expect(contents[0]?.length == 3)
        #expect(contents[0]?.preview?.stringValue == "abc")
        #expect(contents[1] == nil)
        #expect(contents[2]?.kind == .list)
        #expect(contents[2]?.length == 2)
        #expect(contents[2]?.preview?.stringArrayValue == ["x", "y"])
        #expect(channel.sentCommands.map(\.first) == ["STRLEN", "GET", "LLEN", "LRANGE"])
    }

    @Test("A key whose type changed under the probe fails the page rather than showing wrong contents")
    func wrongTypeThrows() async throws {
        let channel = StubRedisChannel([
            .error("WRONGTYPE Operation against a key holding the wrong kind of value"),
            .error("WRONGTYPE Operation against a key holding the wrong kind of value"),
        ])
        await #expect(throws: RedisPluginError.self) {
            try await channel.readContents(
                of: ["app:h"],
                describedAs: [RedisKeyDescription(typeName: "hash", ttlSeconds: -1)]
            )
        }
    }
}

@Suite("Redis key type names")
struct RedisKeyTypeNamesTests {
    @Test("A declined TYPE is nil and an answered one is its name")
    func declinedIsNil() async throws {
        let channel = StubRedisChannel([.status("string"), keyDenied])
        #expect(try await channel.keyTypeNames(["app:1", "other:1"]) == ["string", nil])
    }

    @Test("No keys sends nothing")
    func emptySendsNothing() async throws {
        let channel = StubRedisChannel([])
        #expect(try await channel.keyTypeNames([]).isEmpty)
        #expect(channel.sentCommands.isEmpty)
    }
}
