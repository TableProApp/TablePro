//
//  RedisClusterCursorTests.swift
//  TableProTests
//
//  A cluster SCAN walks one node at a time. Redis accepts another node's cursor without
//  complaining and answers with a plausible page, so a cursor that names the wrong node loses
//  keys silently. These tests pin the behaviour that makes that detectable.
//

import Foundation
import Testing

private let nodes = ["a1b2", "c3d4", "e5f6"]

@Suite("Redis cluster cursor - walking the nodes")
struct RedisClusterCursorWalkTests {
    @Test("A fresh scan starts on the first node")
    func startsAtFirstNode() {
        #expect(RedisClusterCursor.decode("0", orderedNodeIds: nodes)
            == .node(id: "a1b2", cursor: "0", restarted: false))
    }

    @Test("A node that is still going keeps its own cursor")
    func keepsNodeCursor() {
        let next = RedisClusterCursor.advance(after: "a1b2", nodeCursor: "16433", orderedNodeIds: nodes)
        #expect(RedisClusterCursor.decode(next, orderedNodeIds: nodes)
            == .node(id: "a1b2", cursor: "16433", restarted: false))
    }

    @Test("A node that finishes hands over to the next one at zero")
    func advancesToNextNode() {
        let next = RedisClusterCursor.advance(after: "a1b2", nodeCursor: "0", orderedNodeIds: nodes)
        #expect(RedisClusterCursor.decode(next, orderedNodeIds: nodes)
            == .node(id: "c3d4", cursor: "0", restarted: false))
    }

    @Test("The last node finishing ends the scan")
    func lastNodeEndsScan() {
        let next = RedisClusterCursor.advance(after: "e5f6", nodeCursor: "0", orderedNodeIds: nodes)
        #expect(next == RedisClusterCursor.start)
    }

    @Test("A full walk visits every node exactly once")
    func visitsEveryNode() {
        var cursor = RedisClusterCursor.start
        var visited: [String] = []
        for _ in 0 ..< 10 {
            guard case .node(let id, _, _) = RedisClusterCursor.decode(cursor, orderedNodeIds: nodes) else { break }
            visited.append(id)
            cursor = RedisClusterCursor.advance(after: id, nodeCursor: "0", orderedNodeIds: nodes)
            if cursor == RedisClusterCursor.start { break }
        }
        #expect(visited == nodes)
    }
}

@Suite("Redis cluster cursor - topology changes")
struct RedisClusterCursorTopologyTests {
    @Test("A cursor naming a node the cluster no longer has restarts rather than scanning the wrong one")
    func unknownNodeRestarts() {
        let stale = RedisClusterCursor.encode(nodeId: "gone", nodeCursor: "500")
        #expect(RedisClusterCursor.decode(stale, orderedNodeIds: nodes)
            == .node(id: "a1b2", cursor: "0", restarted: true))
    }

    @Test("A cursor with no node in it restarts")
    func malformedRestarts() {
        #expect(RedisClusterCursor.decode("99999", orderedNodeIds: nodes)
            == .node(id: "a1b2", cursor: "0", restarted: true))
    }

    @Test("An empty topology has nothing to scan")
    func emptyTopologyFinishes() {
        #expect(RedisClusterCursor.decode("0", orderedNodeIds: []) == .finished)
    }

    @Test("Advancing from a node that is no longer listed ends the scan rather than looping")
    func unknownNodeEndsAdvance() {
        #expect(RedisClusterCursor.advance(after: "gone", nodeCursor: "0", orderedNodeIds: nodes)
            == RedisClusterCursor.start)
    }

    /// A node with no reported id falls back to "host:port", and a hostname can contain a hyphen.
    /// Splitting at the first one read the id as "redis", restarted the walk every page, and made
    /// browsing a cluster loop forever.
    @Test("A hyphenated node id survives the round trip")
    func hyphenatedNodeIdRoundTrips() {
        let hosts = ["redis-0001.abc.cache.amazonaws.com:6379", "redis-0002.abc.cache.amazonaws.com:6379"]
        let encoded = RedisClusterCursor.encode(nodeId: hosts[0], nodeCursor: "17")
        #expect(RedisClusterCursor.decode(encoded, orderedNodeIds: hosts)
            == .node(id: hosts[0], cursor: "17", restarted: false))
    }

    @Test("A hyphenated node id still advances to the next node")
    func hyphenatedNodeIdAdvances() {
        let hosts = ["redis-0001.example.com:6379", "redis-0002.example.com:6379"]
        let next = RedisClusterCursor.advance(after: hosts[0], nodeCursor: "0", orderedNodeIds: hosts)
        #expect(RedisClusterCursor.decode(next, orderedNodeIds: hosts)
            == .node(id: hosts[1], cursor: "0", restarted: false))
    }

    @Test("A cursor round-trips through encode and decode")
    func roundTrips() {
        let encoded = RedisClusterCursor.encode(nodeId: "c3d4", nodeCursor: "4096")
        #expect(RedisClusterCursor.decode(encoded, orderedNodeIds: nodes)
            == .node(id: "c3d4", cursor: "4096", restarted: false))
    }
}
