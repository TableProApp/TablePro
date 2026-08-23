//
//  RedisClusterTopology.swift
//  RedisDriverPlugin
//
//  The slot-to-node map, parsed from CLUSTER SHARDS (Redis 7+) or CLUSTER SLOTS.
//  Both reply shapes verified on Redis 8.10.1.
//

import Foundation

struct RedisClusterNode: Equatable, Sendable {
    let id: String
    let address: RedisNodeAddress
    let isReplica: Bool
    let isHealthy: Bool
}

struct RedisClusterShard: Equatable, Sendable {
    let slots: [ClosedRange<Int>]
    let master: RedisClusterNode
    let replicas: [RedisClusterNode]
}

struct RedisClusterTopology: Equatable, Sendable {
    let shards: [RedisClusterShard]

    var masters: [RedisClusterNode] { shards.map(\.master) }

    var allNodes: [RedisClusterNode] {
        shards.flatMap { [$0.master] + $0.replicas }
    }

    /// Sorted by address so a node's ordinal is stable for anything that needs a deterministic walk.
    var orderedMasters: [RedisClusterNode] {
        masters.sorted { $0.address.identifier < $1.address.identifier }
    }

    var coversAllSlots: Bool {
        let covered = shards.flatMap(\.slots).reduce(into: 0) { $0 += $1.count }
        return covered == RedisKeySlot.slotCount
    }

    func master(forSlot slot: Int) -> RedisClusterNode? {
        shards.first { shard in shard.slots.contains { $0.contains(slot) } }?.master
    }

    func node(withAddress address: RedisNodeAddress) -> RedisClusterNode? {
        allNodes.first { $0.address == address }
    }

    /// Applies a MOVED without a full reload. Redis clients patch the single slot and reload
    /// periodically rather than on every redirect.
    func movingSlot(_ slot: Int, to address: RedisNodeAddress) -> RedisClusterTopology {
        guard let targetShardIndex = shards.firstIndex(where: { $0.master.address == address }) else {
            return self
        }
        var updated: [RedisClusterShard] = []
        updated.reserveCapacity(shards.count)
        for (index, shard) in shards.enumerated() {
            var slots = index == targetShardIndex
                ? merge(shard.slots, adding: slot)
                : remove(slot, from: shard.slots)
            slots.sort { $0.lowerBound < $1.lowerBound }
            updated.append(RedisClusterShard(slots: slots, master: shard.master, replicas: shard.replicas))
        }
        return RedisClusterTopology(shards: updated)
    }

    private func merge(_ ranges: [ClosedRange<Int>], adding slot: Int) -> [ClosedRange<Int>] {
        guard !ranges.contains(where: { $0.contains(slot) }) else { return ranges }
        return ranges + [slot ... slot]
    }

    private func remove(_ slot: Int, from ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        ranges.flatMap { range -> [ClosedRange<Int>] in
            guard range.contains(slot) else { return [range] }
            var pieces: [ClosedRange<Int>] = []
            if range.lowerBound <= slot - 1 { pieces.append(range.lowerBound ... slot - 1) }
            if slot + 1 <= range.upperBound { pieces.append(slot + 1 ... range.upperBound) }
            return pieces
        }
    }
}

enum RedisClusterTopologyParser {
    /// CLUSTER SHARDS: [ [ "slots", [start, end, ...], "nodes", [ {id, port, ip, endpoint, role, health}, ... ] ], ... ]
    static func parseShards(_ reply: RedisReply, fallbackHost: String) -> RedisClusterTopology? {
        guard case .array(let shardReplies) = reply, !shardReplies.isEmpty else { return nil }
        var shards: [RedisClusterShard] = []
        for shardReply in shardReplies {
            guard let map = flatMap(shardReply) else { return nil }
            guard case .array(let slotNumbers)? = map["slots"] else { return nil }
            let bounds = slotNumbers.compactMap(\.intValue)
            guard bounds.count % 2 == 0 else { return nil }
            var ranges: [ClosedRange<Int>] = []
            for index in stride(from: 0, to: bounds.count, by: 2) where bounds[index] <= bounds[index + 1] {
                ranges.append(bounds[index] ... bounds[index + 1])
            }

            guard case .array(let nodeReplies)? = map["nodes"] else { return nil }
            var master: RedisClusterNode?
            var replicas: [RedisClusterNode] = []
            for nodeReply in nodeReplies {
                guard let node = parseShardNode(nodeReply, fallbackHost: fallbackHost) else { continue }
                if node.isReplica { replicas.append(node) } else { master = node }
            }
            guard let master, !ranges.isEmpty else { continue }
            shards.append(RedisClusterShard(slots: ranges, master: master, replicas: replicas))
        }
        return shards.isEmpty ? nil : RedisClusterTopology(shards: shards)
    }

    /// CLUSTER SLOTS: [ [ start, end, [ip, port, id, meta?], [replica...] ], ... ]
    static func parseSlots(_ reply: RedisReply, fallbackHost: String) -> RedisClusterTopology? {
        guard case .array(let rangeReplies) = reply, !rangeReplies.isEmpty else { return nil }
        var shards: [RedisClusterShard] = []
        for rangeReply in rangeReplies {
            guard case .array(let parts) = rangeReply, parts.count >= 3,
                  let start = parts[0].intValue, let end = parts[1].intValue, start <= end else { continue }
            var master: RedisClusterNode?
            var replicas: [RedisClusterNode] = []
            for (offset, nodeReply) in parts.dropFirst(2).enumerated() {
                guard let node = parseSlotsNode(nodeReply, isReplica: offset > 0, fallbackHost: fallbackHost) else {
                    continue
                }
                if node.isReplica { replicas.append(node) } else { master = node }
            }
            guard let master else { continue }
            shards.append(RedisClusterShard(slots: [start ... end], master: master, replicas: replicas))
        }
        return shards.isEmpty ? nil : RedisClusterTopology(shards: shards)
    }

    private static func parseShardNode(_ reply: RedisReply, fallbackHost: String) -> RedisClusterNode? {
        guard let map = flatMap(reply) else { return nil }
        let endpoint = map["endpoint"]?.stringValue ?? ""
        let ip = map["ip"]?.stringValue ?? ""
        guard let port = map["port"]?.intValue ?? map["tls-port"]?.intValue else { return nil }
        let host = resolveHost(preferred: endpoint, alternate: ip, fallback: fallbackHost)
        let role = map["role"]?.stringValue?.lowercased() ?? "master"
        let health = map["health"]?.stringValue?.lowercased() ?? "online"
        return RedisClusterNode(
            id: map["id"]?.stringValue ?? "\(host):\(port)",
            address: RedisNodeAddress(host: host, port: port),
            isReplica: role == "replica" || role == "slave",
            isHealthy: health == "online"
        )
    }

    private static func parseSlotsNode(
        _ reply: RedisReply,
        isReplica: Bool,
        fallbackHost: String
    ) -> RedisClusterNode? {
        guard case .array(let fields) = reply, fields.count >= 2, let port = fields[1].intValue else { return nil }
        let host = resolveHost(preferred: fields[0].stringValue ?? "", alternate: "", fallback: fallbackHost)
        let id = fields.count >= 3 ? (fields[2].stringValue ?? "") : ""
        return RedisClusterNode(
            id: id.isEmpty ? "\(host):\(port)" : id,
            address: RedisNodeAddress(host: host, port: port),
            isReplica: isReplica,
            isHealthy: true
        )
    }

    /// Redis reports an unknown endpoint as an empty string, a nil bulk string or "?", all of which
    /// mean "reuse the address you reached me on".
    private static func resolveHost(preferred: String, alternate: String, fallback: String) -> String {
        for candidate in [preferred, alternate] where !candidate.isEmpty && candidate != "?" {
            return candidate
        }
        return fallback
    }

    /// RESP2 returns a map as a flat key/value array; RESP3 returns a real map, which the reply
    /// parser also flattens into `.array`.
    private static func flatMap(_ reply: RedisReply) -> [String: RedisReply]? {
        guard case .array(let items) = reply, items.count % 2 == 0 else { return nil }
        var map: [String: RedisReply] = [:]
        for index in stride(from: 0, to: items.count, by: 2) {
            guard let key = items[index].stringValue else { continue }
            map[key] = items[index + 1]
        }
        return map
    }
}
