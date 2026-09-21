//
//  RedisCommandRoutingTests.swift
//  TableProTests
//
//  Key positions and policies here match what `COMMAND INFO` reports on Redis 8.10.1, and the
//  entries are shaped the way its RESP2 reply is: a bulk name, which for a subcommand already
//  carries the container (`config|set`), and flags as simple strings.
//

import Foundation
import Testing

private func args(_ tokens: String...) -> [Data] { tokens.map { Data($0.utf8) } }

private func commandEntry(
    name: String,
    flags: [String] = [],
    firstKey: Int = 0,
    lastKey: Int = 0,
    step: Int = 0,
    tips: [String] = [],
    subcommands: [RedisReply] = []
) -> RedisReply {
    .array([
        .string(name),
        .integer(-1),
        .array(flags.map { RedisReply.status($0) }),
        .integer(Int64(firstKey)),
        .integer(Int64(lastKey)),
        .integer(Int64(step)),
        .array([]),
        .array(tips.map { RedisReply.string($0) }),
        .array([]),
        .array(subcommands),
    ])
}

@Suite("Redis command routing - key extraction")
struct RedisCommandRoutingKeyTests {
    let routing = RedisCommandRouting()

    @Test("A single-key command yields its one key")
    func singleKey() {
        #expect(routing.keys(in: args("GET", "foo")).map { String(data: $0, encoding: .utf8) } == ["foo"])
    }

    @Test("A variadic command yields every key")
    func variadicKeys() {
        let keys = routing.keys(in: args("DEL", "a", "b", "c")).compactMap { String(data: $0, encoding: .utf8) }
        #expect(keys == ["a", "b", "c"])
    }

    @Test("A stepped command skips the values between keys")
    func steppedKeys() {
        let keys = routing.keys(in: args("MSET", "a", "1", "b", "2")).compactMap { String(data: $0, encoding: .utf8) }
        #expect(keys == ["a", "b"])
    }

    @Test("A two-key command yields both")
    func twoKeys() {
        let keys = routing.keys(in: args("RENAME", "old", "new")).compactMap { String(data: $0, encoding: .utf8) }
        #expect(keys == ["old", "new"])
    }

    @Test("A keyless command yields nothing")
    func keylessCommand() {
        #expect(routing.keys(in: args("DBSIZE")).isEmpty)
        #expect(routing.keys(in: args("INFO", "server")).isEmpty)
    }

    @Test("An unknown command yields nothing rather than guessing its first argument")
    func unknownCommandHasNoKeys() {
        #expect(routing.keys(in: args("SOMETHINGNEW", "arg")).isEmpty)
    }

    @Test("A container command resolves through its subcommand entry")
    func containerSubcommand() {
        #expect(routing.spec(for: args("CONFIG", "SET", "maxmemory", "0"))?.requestPolicy == .allNodes)
        #expect(routing.spec(for: args("CONFIG", "GET", "maxmemory"))?.requestPolicy == nil)
    }

    @Test("Key duplicates are preserved, because EXISTS counts each one")
    func keepsDuplicates() {
        let keys = routing.keys(in: args("EXISTS", "a", "a", "a")).compactMap { String(data: $0, encoding: .utf8) }
        #expect(keys == ["a", "a", "a"])
    }
}

@Suite("Redis command routing - policies")
struct RedisCommandRoutingPolicyTests {
    let routing = RedisCommandRouting()

    @Test("DBSIZE fans out and sums")
    func dbsize() {
        let spec = routing.spec(for: args("DBSIZE"))
        #expect(spec?.requestPolicy == .allShards)
        #expect(spec?.responsePolicy == .aggSum)
    }

    @Test("KEYS fans out with no response policy, so its arrays concatenate")
    func keys() {
        let spec = routing.spec(for: args("KEYS", "*"))
        #expect(spec?.requestPolicy == .allShards)
        #expect(spec?.responsePolicy == nil)
    }

    @Test("FLUSHDB fans out and requires every shard to succeed")
    func flushdb() {
        let spec = routing.spec(for: args("FLUSHDB"))
        #expect(spec?.requestPolicy == .allShards)
        #expect(spec?.responsePolicy == .allSucceeded)
    }

    @Test("A fan-out that is no read and wants every node to succeed changes what it reaches")
    func changesEveryNodeItReaches() {
        #expect(routing.spec(for: args("FLUSHDB"))?.changesEveryNodeItReaches == true)
        #expect(routing.spec(for: args("CONFIG", "SET", "maxmemory", "0"))?.changesEveryNodeItReaches == true)
        #expect(routing.spec(for: args("DBSIZE"))?.changesEveryNodeItReaches == false)
        #expect(routing.spec(for: args("KEYS", "*"))?.changesEveryNodeItReaches == false)
    }

    @Test("INFO is special, so it goes to one node rather than being merged")
    func info() {
        #expect(routing.spec(for: args("INFO"))?.responsePolicy == .special)
    }

    @Test("DEL and MGET are multi-shard")
    func multiShard() {
        #expect(routing.spec(for: args("DEL", "a"))?.requestPolicy == .multiShard)
        #expect(routing.spec(for: args("MGET", "a"))?.requestPolicy == .multiShard)
    }

    @Test("SCRIPT LOAD must reach replicas too")
    func scriptLoad() {
        #expect(routing.spec(for: args("SCRIPT", "LOAD", "return 1"))?.requestPolicy == .allNodes)
    }

    @Test("Read-only commands are recognised, and GETEX is not one of them")
    func readOnlyClassification() {
        #expect(routing.isReadOnly(args("GET", "k")))
        #expect(routing.isReadOnly(args("EXISTS", "k")))
        #expect(!routing.isReadOnly(args("SET", "k", "v")))
        #expect(!routing.isReadOnly(args("INCR", "k")))
        #expect(!routing.isReadOnly(args("GETEX", "k")))
    }

    /// Only a write can leave a cluster half changed, so this flag decides whether a split command
    /// one shard refused is reported as partly applied.
    @Test("Writes are recognised, and neither a read nor PING or CONFIG SET is one")
    func writeClassification() {
        for name in ["DEL", "UNLINK", "MSET", "FLUSHDB", "FLUSHALL", "SET", "LMPOP", "SORT"] {
            #expect(routing.spec(for: args(name, "k"))?.isWrite == true, "\(name) should be a write")
        }
        for name in ["PING", "EXISTS", "DBSIZE", "GET", "EVAL", "MGET"] {
            #expect(routing.spec(for: args(name, "k"))?.isWrite == false, "\(name) should not be a write")
        }
        #expect(routing.spec(for: args("CONFIG", "SET", "maxmemory", "0"))?.isWrite == false)
    }

    @Test("Commands whose keys only COMMAND GETKEYS knows are flagged")
    func movableKeys() {
        for name in ["EVAL", "SORT", "GEORADIUS", "LMPOP", "XREAD", "ZUNIONSTORE"] {
            #expect(routing.needsServerKeyResolution(for: args(name, "x")), "\(name) should be movablekeys")
        }
        #expect(!routing.needsServerKeyResolution(for: args("GET", "x")))
    }

    /// `OBJECT ENCODING k` and `MEMORY USAGE k` take a key, but the container itself does not, and
    /// hashing on the literal subcommand name is the mistake the unknown-command path avoids.
    /// Redis reports a subcommand's key position against the full argument list, so that key sits
    /// at index 2, not 1.
    @Test("A container command takes no key of its own")
    func containersTakeNoKey() {
        #expect(routing.keys(in: args("OBJECT", "HELP")).isEmpty)
        #expect(routing.keys(in: args("MEMORY", "DOCTOR")).isEmpty)
        let encoding = routing.keys(in: args("OBJECT", "ENCODING", "k"))
            .compactMap { String(data: $0, encoding: .utf8) }
        #expect(encoding == ["k"])
        let usage = routing.keys(in: args("MEMORY", "USAGE", "k"))
            .compactMap { String(data: $0, encoding: .utf8) }
        #expect(usage == ["k"])
    }

    /// MSETNX is all or nothing. Splitting it across shards would set some keys and not others,
    /// which is the guarantee it exists for.
    @Test("MSETNX is not split across shards")
    func msetnxIsNotSplit() {
        #expect(routing.spec(for: args("MSETNX", "a", "1"))?.requestPolicy == nil)
    }

    /// ZUNIONSTORE takes a destination and then a count, so treating every argument as a key
    /// hashed the count and the options and picked the wrong shard.
    @Test("A store-form set operation does not treat its arguments as keys")
    func storeFormsDoNotSpanArguments() throws {
        let spec = try #require(routing.spec(for: args("ZUNIONSTORE", "dst", "2", "a", "b")))
        #expect(spec.lastKey == 1)
        #expect(spec.hasMovableKeys)
    }
}

@Suite("Redis command routing - COMMAND reply")
struct RedisCommandRoutingParsingTests {
    @Test("Reads key positions from the server's own answer")
    func parsesKeyPositions() throws {
        let reply = RedisReply.array([
            commandEntry(name: "mget", flags: ["readonly"], firstKey: 1, lastKey: -1, step: 1,
                         tips: ["request_policy:multi_shard"]),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: reply))
        let spec = try #require(routing.spec(for: args("MGET", "a", "b")))
        #expect(spec.firstKey == 1)
        #expect(spec.lastKey == -1)
        #expect(spec.requestPolicy == .multiShard)
        #expect(spec.isReadOnly)
    }

    /// Redis already names a subcommand `function|load`. Prefixing the container again keyed it as
    /// `function|function|load`, which no lookup ever reaches, so the command ran on one node.
    @Test("Reads a policy that only exists on a subcommand entry")
    func parsesSubcommandPolicy() throws {
        let reply = RedisReply.array([
            commandEntry(name: "function", subcommands: [
                commandEntry(
                    name: "function|load",
                    flags: ["write", "denyoom", "noscript"],
                    tips: ["request_policy:all_shards", "response_policy:all_succeeded"]
                ),
            ]),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: reply))
        let spec = try #require(routing.spec(for: args("FUNCTION", "LOAD", "#!lua name=lib")))
        #expect(spec.name == "function|load")
        #expect(spec.requestPolicy == .allShards)
        #expect(spec.responsePolicy == .allSucceeded)
    }

    @Test("Reads the key positions of a subcommand entry")
    func parsesSubcommandKeyPositions() throws {
        let reply = RedisReply.array([
            commandEntry(name: "xinfo", subcommands: [
                commandEntry(name: "xinfo|stream", flags: ["readonly"], firstKey: 2, lastKey: 2, step: 1),
            ]),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: reply))
        let keys = routing.keys(in: args("XINFO", "STREAM", "orders")).compactMap { String(data: $0, encoding: .utf8) }
        #expect(keys == ["orders"])
        #expect(routing.isReadOnly(args("XINFO", "STREAM", "orders")))
    }

    /// The curated `config|set` says all_nodes. A server that tips it differently is the one that
    /// knows, and its entry could only win once it was keyed by the name the lookup uses.
    @Test("A server's subcommand entry overrides the curated one")
    func serverSubcommandOverridesCurated() throws {
        let reply = RedisReply.array([
            commandEntry(name: "config", subcommands: [
                commandEntry(name: "config|set", tips: ["request_policy:all_shards", "response_policy:all_succeeded"]),
            ]),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: reply))
        #expect(routing.spec(for: args("CONFIG", "SET", "maxmemory", "0"))?.requestPolicy == .allShards)
    }

    /// A nested entry keyed by its bare name would replace the top-level SET with a keyless
    /// entry, and every SET would then go to an arbitrary master instead of the key's owner.
    @Test("A nested entry not named under its container cannot replace a top-level command")
    func nestedEntryCannotReplaceTopLevelCommand() throws {
        let reply = RedisReply.array([
            commandEntry(name: "config", subcommands: [
                commandEntry(name: "set", tips: ["request_policy:all_nodes", "response_policy:all_succeeded"]),
            ]),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: reply))
        let keys = routing.keys(in: args("SET", "k", "v")).compactMap { String(data: $0, encoding: .utf8) }
        #expect(keys == ["k"])
        #expect(routing.spec(for: args("SET", "k", "v"))?.requestPolicy == nil)
        #expect(routing.spec(for: args("CONFIG", "SET", "a", "b"))?.requestPolicy == .allNodes)
    }

    @Test("Reads the write flag")
    func parsesWriteFlag() throws {
        let reply = RedisReply.array([
            commandEntry(name: "del", flags: ["write"], firstKey: 1, lastKey: -1, step: 1,
                         tips: ["request_policy:multi_shard", "response_policy:agg_sum"]),
            commandEntry(name: "ping", flags: ["fast", "sentinel"],
                         tips: ["request_policy:all_shards", "response_policy:all_succeeded"]),
            commandEntry(name: "config", subcommands: [
                commandEntry(name: "config|set", flags: ["admin", "noscript", "loading", "stale"],
                             tips: ["request_policy:all_nodes", "response_policy:all_succeeded"]),
            ]),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: reply))
        #expect(routing.spec(for: args("DEL", "a"))?.isWrite == true)
        #expect(routing.spec(for: args("PING"))?.isWrite == false)
        #expect(routing.spec(for: args("CONFIG", "SET", "a", "b"))?.isWrite == false)
    }

    /// A Redis 6 entry carries its flags but no tips, so the curated policy fills in; the write
    /// flag has to survive that merge from either side.
    @Test("A merged entry keeps the write flag")
    func mergeKeepsWriteFlag() throws {
        let sixElementEntry = RedisReply.array([
            .string("flushdb"), .integer(-1), .array([.status("write")]),
            .integer(0), .integer(0), .integer(0),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: .array([sixElementEntry])))
        let spec = try #require(routing.spec(for: args("FLUSHDB")))
        #expect(spec.isWrite)
        #expect(spec.requestPolicy == .allShards)
    }

    @Test("Reads the movablekeys flag")
    func parsesMovableKeys() throws {
        let reply = RedisReply.array([commandEntry(name: "eval", flags: ["movablekeys"])])
        let routing = try #require(RedisCommandRouting.parse(commandReply: reply))
        #expect(routing.needsServerKeyResolution(for: args("EVAL", "script", "0")))
    }

    /// Command tips arrived in Redis 7. A 6.x server reports key positions and no tips, so taking
    /// its answer wholesale would leave DBSIZE, KEYS and FLUSHDB with no fan-out policy and send
    /// each of them to a single shard of a cluster.
    @Test("A Redis 6 answer keeps the curated fan-out policies")
    func redis6AnswerKeepsPolicies() throws {
        let sixElementEntry = RedisReply.array([
            .string("dbsize"), .integer(1), .array([.string("readonly"), .string("fast")]),
            .integer(0), .integer(0), .integer(0),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: .array([sixElementEntry])))
        let spec = try #require(routing.spec(for: args("DBSIZE")))
        #expect(spec.requestPolicy == .allShards)
        #expect(spec.responsePolicy == .aggSum)
    }

    @Test("A Redis 6 answer still contributes the key positions it does report")
    func redis6AnswerKeepsKeyPositions() throws {
        let entry = RedisReply.array([
            .string("newcmd"), .integer(2), .array([.string("readonly")]),
            .integer(1), .integer(1), .integer(1),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: .array([entry])))
        let keys = routing.keys(in: args("NEWCMD", "k")).compactMap { String(data: $0, encoding: .utf8) }
        #expect(keys == ["k"])
    }

    @Test("A server that does report tips overrides the curated policy")
    func serverTipsWin() throws {
        let entry = RedisReply.array([
            .string("dbsize"), .integer(1), .array([.string("readonly")]),
            .integer(0), .integer(0), .integer(0),
            .array([]), .array([.string("request_policy:all_nodes")]), .array([]), .array([]),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: .array([entry])))
        #expect(routing.spec(for: args("DBSIZE"))?.requestPolicy == .allNodes)
    }

    @Test("Commands the server did not mention keep their curated entry")
    func unmentionedCommandsSurvive() throws {
        let entry = RedisReply.array([
            .string("get"), .integer(2), .array([.string("readonly")]),
            .integer(1), .integer(1), .integer(1),
        ])
        let routing = try #require(RedisCommandRouting.parse(commandReply: .array([entry])))
        #expect(routing.spec(for: args("KEYS", "*"))?.requestPolicy == .allShards)
    }

    @Test("An empty or refused COMMAND falls back to the curated table")
    func fallsBackWhenRefused() {
        #expect(RedisCommandRouting.parse(commandReply: .array([])) == nil)
        #expect(RedisCommandRouting.parse(commandReply: .error("NOPERM")) == nil)
        #expect(RedisCommandRouting().spec(for: args("DBSIZE"))?.responsePolicy == .aggSum)
    }
}

@Suite("Redis command routing - how far a command fans out on a cluster")
struct RedisClusterFanOutTests {
    let routing = RedisCommandRouting()

    /// LATENCY DOCTOR is tipped all_nodes with a special response, measured on Redis 8.10.1.
    @Test("A special response goes to one node whatever the request policy")
    func specialResponseGoesToOneNode() throws {
        let reply = RedisReply.array([
            commandEntry(name: "latency", subcommands: [
                commandEntry(
                    name: "latency|doctor",
                    flags: ["admin", "noscript", "loading", "stale"],
                    tips: ["nondeterministic_output", "request_policy:all_nodes", "response_policy:special"]
                ),
            ]),
        ])
        let parsed = try #require(RedisCommandRouting.parse(commandReply: reply))
        #expect(parsed.spec(for: args("LATENCY", "DOCTOR"))?.clusterFanOut == .single)
        #expect(routing.spec(for: args("INFO"))?.clusterFanOut == .single)
    }

    @Test("Each policy maps to how far the command goes")
    func policies() {
        #expect(routing.spec(for: args("CONFIG", "SET", "maxmemory", "0"))?.clusterFanOut == .everyNode)
        #expect(routing.spec(for: args("DBSIZE"))?.clusterFanOut == .everyPrimary)
        #expect(routing.spec(for: args("DEL", "a", "b"))?.clusterFanOut == .keyedShards)
        #expect(routing.spec(for: args("GET", "k"))?.clusterFanOut == .single)
        #expect(routing.spec(for: args("SCAN", "0"))?.clusterFanOut == .single)
    }
}

@Suite("Redis command routing - key index arithmetic")
struct RedisCommandSpecIndexTests {
    private func spec(first: Int, last: Int, step: Int) -> RedisCommandSpec {
        RedisCommandSpec(
            name: "x", firstKey: first, lastKey: last, step: step,
            isReadOnly: false, isWrite: false, hasMovableKeys: false, requestPolicy: nil, responsePolicy: nil
        )
    }

    @Test("A negative last key counts back from the end")
    func negativeLastKey() {
        #expect(spec(first: 1, last: -1, step: 1).keyIndices(forArgumentCount: 4) == [1, 2, 3])
    }

    @Test("A step skips interleaved values")
    func stepSkipsValues() {
        #expect(spec(first: 1, last: -1, step: 2).keyIndices(forArgumentCount: 5) == [1, 3])
    }

    @Test("A keyless spec yields nothing")
    func keylessYieldsNothing() {
        #expect(spec(first: 0, last: 0, step: 0).keyIndices(forArgumentCount: 3).isEmpty)
    }

    @Test("A command shorter than its first key yields nothing")
    func tooFewArgumentsYieldNothing() {
        #expect(spec(first: 1, last: 1, step: 1).keyIndices(forArgumentCount: 1).isEmpty)
    }
}
