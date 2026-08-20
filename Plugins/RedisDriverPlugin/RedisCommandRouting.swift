//
//  RedisCommandRouting.swift
//  RedisDriverPlugin
//
//  Where a command has to go in a cluster, and how replies from several shards combine.
//
//  The table is built from one COMMAND call at connect. Redis 7 answers with the request and
//  response policy tips that exist precisely so a cluster client does not have to hard-code this,
//  and the policy for a container command lives on its subcommand entry (COMMAND INFO config
//  carries no tips at all; config|set is the entry that says all_nodes). A curated table covers
//  pre-7 servers and ACL-restricted users, who get NOPERM for COMMAND just as they do for
//  CLUSTER SLOTS.
//

import Foundation

enum RedisRequestPolicy: String, Sendable, Equatable {
    case allNodes = "all_nodes"
    case allShards = "all_shards"
    case multiShard = "multi_shard"
    case special
}

enum RedisResponsePolicy: String, Sendable, Equatable {
    case oneSucceeded = "one_succeeded"
    case allSucceeded = "all_succeeded"
    case aggLogicalAnd = "agg_logical_and"
    case aggLogicalOr = "agg_logical_or"
    case aggMin = "agg_min"
    case aggMax = "agg_max"
    case aggSum = "agg_sum"
    case special
}

struct RedisCommandSpec: Sendable, Equatable {
    let name: String
    let firstKey: Int
    let lastKey: Int
    let step: Int
    let isReadOnly: Bool
    let hasMovableKeys: Bool
    let requestPolicy: RedisRequestPolicy?
    let responsePolicy: RedisResponsePolicy?

    var declaresKeys: Bool { firstKey > 0 && step > 0 }

    func fillingPoliciesFrom(_ fallback: RedisCommandSpec?) -> RedisCommandSpec {
        guard let fallback, requestPolicy == nil, responsePolicy == nil else { return self }
        return RedisCommandSpec(
            name: name,
            firstKey: firstKey,
            lastKey: lastKey,
            step: step,
            isReadOnly: isReadOnly || fallback.isReadOnly,
            hasMovableKeys: hasMovableKeys || fallback.hasMovableKeys,
            requestPolicy: fallback.requestPolicy,
            responsePolicy: fallback.responsePolicy
        )
    }

    /// Argument positions holding a key, for a command of `argumentCount` total tokens
    /// (the command name included, so index 0 is the name).
    func keyIndices(forArgumentCount argumentCount: Int) -> [Int] {
        guard declaresKeys, argumentCount > firstKey else { return [] }
        let last = lastKey < 0 ? argumentCount + lastKey : min(lastKey, argumentCount - 1)
        guard last >= firstKey else { return [] }
        return Array(stride(from: firstKey, through: last, by: step))
    }
}

struct RedisCommandRouting: Sendable {
    private let specs: [String: RedisCommandSpec]

    init(specs: [String: RedisCommandSpec] = [:]) {
        self.specs = specs.isEmpty ? Self.curated : specs
    }

    /// Resolves the most specific entry: a container's subcommand first, then the container itself.
    func spec(for arguments: [Data]) -> RedisCommandSpec? {
        guard let name = arguments.first.flatMap({ String(data: $0, encoding: .utf8) })?.lowercased() else {
            return nil
        }
        if arguments.count > 1,
           let sub = String(data: arguments[1], encoding: .utf8)?.lowercased(),
           let nested = specs["\(name)|\(sub)"] {
            return nested
        }
        return specs[name]
    }

    func keys(in arguments: [Data]) -> [Data] {
        guard let spec = spec(for: arguments) else { return [] }
        return spec.keyIndices(forArgumentCount: arguments.count).compactMap { index in
            index < arguments.count ? arguments[index] : nil
        }
    }

    /// True when the command's keys cannot be derived from the static positions and only
    /// COMMAND GETKEYS knows them (EVAL, SORT, GEORADIUS, LMPOP, XREAD and friends).
    func needsServerKeyResolution(for arguments: [Data]) -> Bool {
        spec(for: arguments)?.hasMovableKeys ?? false
    }

    func isReadOnly(_ arguments: [Data]) -> Bool {
        spec(for: arguments)?.isReadOnly ?? false
    }

    /// Command tips only exist from Redis 7. A 6.x server answers COMMAND with the key positions
    /// and no tips at all, so taking its answer wholesale would leave every fan-out policy nil and
    /// quietly send DBSIZE, KEYS and FLUSHDB to one shard of a cluster. The server wins on key
    /// positions, which it always reports, and the curated table fills in a policy it did not.
    static func parse(commandReply reply: RedisReply) -> RedisCommandRouting? {
        guard case .array(let entries) = reply, !entries.isEmpty else { return nil }
        var specs: [String: RedisCommandSpec] = [:]
        for entry in entries {
            collect(entry, container: nil, into: &specs)
        }
        guard !specs.isEmpty else { return nil }

        var merged = curated
        for (name, spec) in specs {
            merged[name] = spec.fillingPoliciesFrom(curated[name])
        }
        return RedisCommandRouting(specs: merged)
    }

    private static func collect(_ entry: RedisReply, container: String?, into specs: inout [String: RedisCommandSpec]) {
        guard case .array(let fields) = entry, fields.count >= 6, let rawName = fields[0].stringValue else { return }
        let name = container.map { "\($0)|\(rawName.lowercased())" } ?? rawName.lowercased()

        let flags = Set((fields[2].stringArrayValue ?? []).map { $0.lowercased() })
        let tips = fields.count >= 8 ? (fields[7].stringArrayValue ?? []) : []
        var request: RedisRequestPolicy?
        var response: RedisResponsePolicy?
        for tip in tips {
            let parts = tip.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "request_policy": request = RedisRequestPolicy(rawValue: parts[1])
            case "response_policy": response = RedisResponsePolicy(rawValue: parts[1])
            default: break
            }
        }

        specs[name] = RedisCommandSpec(
            name: name,
            firstKey: fields[3].intValue ?? 0,
            lastKey: fields[4].intValue ?? 0,
            step: fields[5].intValue ?? 0,
            isReadOnly: flags.contains("readonly"),
            hasMovableKeys: flags.contains("movablekeys"),
            requestPolicy: request,
            responsePolicy: response
        )

        guard fields.count >= 10, case .array(let subcommands) = fields[9] else { return }
        for subcommand in subcommands {
            collect(subcommand, container: name, into: &specs)
        }
    }

    // MARK: - Curated fallback

    private static func spec(
        _ name: String,
        _ firstKey: Int,
        _ lastKey: Int,
        _ step: Int,
        readOnly: Bool = false,
        movable: Bool = false,
        request: RedisRequestPolicy? = nil,
        response: RedisResponsePolicy? = nil
    ) -> RedisCommandSpec {
        RedisCommandSpec(
            name: name, firstKey: firstKey, lastKey: lastKey, step: step,
            isReadOnly: readOnly, hasMovableKeys: movable,
            requestPolicy: request, responsePolicy: response
        )
    }

    /// Covers every command RedisCommandParser can emit plus the ones the driver issues itself.
    /// Values match what Redis 8.10.1 reports for the same commands.
    static let curated: [String: RedisCommandSpec] = {
        var table: [String: RedisCommandSpec] = [:]
        func add(_ spec: RedisCommandSpec) { table[spec.name] = spec }

        for name in ["get", "strlen", "type", "ttl", "pttl", "dump", "hgetall", "hkeys", "hvals", "hlen",
                     "llen", "lrange", "smembers", "scard", "srandmember", "sismember", "zcard", "zscore",
                     "zrange", "zrangebyscore", "zrevrange", "zrevrangebyscore", "zcount", "zrank",
                     "zrevrank", "xrange", "xrevrange", "xlen", "hget", "hmget", "hrandfield",
                     "hscan", "sscan", "zscan", "lpos", "getrange", "bitcount", "object", "memory"] {
            add(spec(name, 1, 1, 1, readOnly: true))
        }
        for name in ["set", "getset", "getdel", "getex", "append", "setrange", "incr", "decr", "incrby",
                     "decrby", "incrbyfloat", "expire", "pexpire", "expireat", "pexpireat", "persist",
                     "hset", "hsetnx", "hdel", "hincrby", "hincrbyfloat", "lpush", "rpush", "lpushx",
                     "rpushx", "lpop", "rpop", "lset", "linsert", "lrem", "ltrim", "sadd", "srem",
                     "spop", "zadd", "zrem", "zincrby", "zpopmin", "zpopmax", "xadd", "xdel", "xtrim",
                     "setex", "psetex", "setnx", "restore"] {
            add(spec(name, 1, 1, 1))
        }
        for name in ["rename", "renamenx", "smove", "lmove", "rpoplpush", "copy"] {
            add(spec(name, 1, 2, 1))
        }
        add(spec("mget", 1, -1, 1, readOnly: true, request: .multiShard))
        add(spec("mset", 1, -1, 2, request: .multiShard, response: .allSucceeded))
        add(spec("msetnx", 1, -1, 2, request: .multiShard, response: .allSucceeded))
        for name in ["del", "unlink"] {
            add(spec(name, 1, -1, 1, request: .multiShard, response: .aggSum))
        }
        for name in ["exists", "touch"] {
            add(spec(name, 1, -1, 1, readOnly: true, request: .multiShard, response: .aggSum))
        }
        for name in ["sunion", "sinter", "sdiff"] {
            add(spec(name, 1, -1, 1, readOnly: true))
        }
        for name in ["sunionstore", "sinterstore", "sdiffstore", "zunionstore", "zinterstore"] {
            add(spec(name, 1, -1, 1))
        }
        for name in ["eval", "evalsha", "fcall", "fcall_ro", "sort", "sort_ro", "georadius",
                     "georadiusbymember", "lmpop", "zmpop", "xread", "xreadgroup", "zdiff", "zunion",
                     "zinter", "sintercard"] {
            add(spec(name, 0, 0, 0, movable: true))
        }

        add(spec("keys", 0, 0, 0, readOnly: true, request: .allShards))
        add(spec("dbsize", 0, 0, 0, readOnly: true, request: .allShards, response: .aggSum))
        add(spec("flushdb", 0, 0, 0, request: .allShards, response: .allSucceeded))
        add(spec("flushall", 0, 0, 0, request: .allShards, response: .allSucceeded))
        add(spec("info", 0, 0, 0, readOnly: true, request: .allShards, response: .special))
        add(spec("randomkey", 0, 0, 0, readOnly: true, request: .allShards, response: .special))
        add(spec("scan", 0, 0, 0, readOnly: true, request: .special, response: .special))
        add(spec("ping", 0, 0, 0, readOnly: true))
        add(spec("select", 0, 0, 0))
        add(spec("auth", 0, 0, 0))
        add(spec("multi", 0, 0, 0))
        add(spec("exec", 0, 0, 0))
        add(spec("discard", 0, 0, 0))
        add(spec("command", 0, 0, 0, readOnly: true))
        add(spec("cluster", 0, 0, 0, readOnly: true))
        add(spec("config", 0, 0, 0))
        add(spec("config|get", 0, 0, 0, readOnly: true))
        add(spec("config|set", 0, 0, 0, request: .allNodes, response: .allSucceeded))
        add(spec("config|resetstat", 0, 0, 0, request: .allNodes, response: .allSucceeded))
        add(spec("script", 0, 0, 0))
        add(spec("script|load", 0, 0, 0, request: .allNodes, response: .allSucceeded))
        add(spec("script|flush", 0, 0, 0, request: .allNodes, response: .allSucceeded))
        add(spec("script|exists", 0, 0, 0, readOnly: true, request: .allShards, response: .aggLogicalAnd))
        add(spec("memory|stats", 0, 0, 0, readOnly: true, request: .allShards, response: .special))
        add(spec("memory|usage", 1, 1, 1, readOnly: true))
        return table
    }()
}
