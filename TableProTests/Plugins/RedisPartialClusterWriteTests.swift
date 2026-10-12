//
//  RedisPartialClusterWriteTests.swift
//  TableProTests
//
//  A split write one shard refused used to read as if nothing ran. Measured on a two-master
//  Redis 8.10.1 cluster with an ACL user limited to `allowed:*`: `DEL allowed:1 forbidden:1`
//  answered `NOPERM No permissions to access a key` and `allowed:1` was already deleted.
//

import Foundation
import TableProPluginKit
import Testing

private struct Dropped: Error, LocalizedError {
    var errorDescription: String? { "No reply from Redis" }
}

private func keys(_ names: String...) -> [Data] { names.map { Data($0.utf8) } }

private let refusal = "NOPERM No permissions to access a key"

struct RedisPartialClusterWriteAssemblyTests {
    private let nodes = ["127.0.0.1:6505", "127.0.0.1:6506"]

    @Test("One part ran and one was refused")
    func ranAndRefused() throws {
        let partial = try #require(RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: nodes,
            keys: [keys("allowed:1"), keys("forbidden:1")],
            replies: [.integer(1), .error(refusal)],
            interruption: nil
        ))
        #expect(partial.parts.map(\.outcome) == [.ran, .refused(refusal)])
        #expect(partial.pluginErrorMessage == "DEL: \(refusal)")
        let detail = try #require(partial.pluginErrorDetail)
        #expect(detail.contains("1 of the 2 hash slots"))
        #expect(detail.hasSuffix("Keys it ran on: allowed:1"))
        #expect(!detail.contains("forbidden:1"))
    }

    @Test("A read one shard refused changed nothing, so it is not a partial write")
    func readIsNotPartial() {
        let partial = RedisPartialClusterWrite.assemble(
            command: "EXISTS",
            isWrite: false,
            nodes: nodes,
            keys: [keys("allowed:1"), keys("forbidden:1")],
            replies: [.integer(1), .error(refusal)],
            interruption: nil
        )
        #expect(partial == nil)
    }

    @Test("A write every part ran is whole")
    func everyPartRan() {
        let partial = RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: nodes,
            keys: [keys("a"), keys("b")],
            replies: [.integer(1), .integer(1)],
            interruption: nil
        )
        #expect(partial == nil)
    }

    @Test("A write no part ran changed nothing")
    func noPartRan() {
        let partial = RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: nodes,
            keys: [keys("forbidden:1"), keys("forbidden:2")],
            replies: [.error(refusal)],
            interruption: nil
        )
        #expect(partial == nil)
    }

    @Test("A send that threw after a part ran leaves the rest unsent")
    func interruption() throws {
        let partial = try #require(RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: nodes + ["127.0.0.1:6507"],
            keys: [keys("a"), keys("b"), keys("k1")],
            replies: [.integer(1)],
            interruption: Dropped()
        ))
        #expect(partial.parts.map(\.outcome) == [.ran, .interrupted("No reply from Redis"), .notSent])
        #expect(partial.pluginErrorMessage == "No reply from Redis")
    }

    @Test("A driver error's own message is the headline, without its detail")
    func driverErrorHeadline() throws {
        let partial = try #require(RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: nodes,
            keys: [keys("a"), keys("b")],
            replies: [.integer(1)],
            interruption: RedisPluginError(code: 0, message: "The cluster is not serving requests: down", detail: "x")
        ))
        #expect(partial.pluginErrorMessage == "The cluster is not serving requests: down")
    }

    @Test("A part queued into an open block while another ran is reported as queued")
    func queuedAndRan() throws {
        let partial = try #require(RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: nodes,
            keys: [keys("allowed:1"), keys("allowed:3")],
            replies: [.integer(1), .status("QUEUED")],
            interruption: nil
        ))
        #expect(partial.pluginErrorMessage == "Redis queued DEL instead of running it.")
        #expect(partial.pluginErrorDetail?.hasSuffix("Keys it ran on: allowed:1") == true)
    }
}

struct RedisPartialClusterWriteDetailTests {
    @Test("A command sent whole to every node names the nodes it ran on")
    func broadcastNamesNodes() throws {
        let partial = try #require(RedisPartialClusterWrite.assemble(
            command: "FLUSHDB",
            isWrite: true,
            nodes: ["127.0.0.1:6505", "127.0.0.1:6506"],
            keys: [],
            replies: [.error("NOPERM User limited has no permissions to run the 'flushdb' command"), .status("OK")],
            interruption: nil
        ))
        let detail = try #require(partial.pluginErrorDetail)
        #expect(detail.contains("1 of the 2 nodes"))
        #expect(detail.hasSuffix("Nodes it ran on: 127.0.0.1:6506"))
    }

    @Test("A long key list stops at twenty and counts the rest")
    func longKeyListIsCapped() throws {
        let ran = (1 ... 25).map { Data("k\($0)".utf8) }
        let partial = try #require(RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: ["n1", "n2"],
            keys: [ran, keys("forbidden:1")],
            replies: [.integer(25), .error(refusal)],
            interruption: nil
        ))
        let detail = try #require(partial.pluginErrorDetail)
        #expect(detail.hasSuffix("k19 k20 and 5 more"))
        #expect(!detail.contains("k21"))
    }

    @Test("A key that needs quoting is listed the way the editor would write it")
    func keysAreQuoted() throws {
        let partial = try #require(RedisPartialClusterWrite.assemble(
            command: "DEL",
            isWrite: true,
            nodes: ["n1", "n2"],
            keys: [keys("with space"), keys("forbidden:1")],
            replies: [.integer(1), .error(refusal)],
            interruption: nil
        ))
        #expect(partial.pluginErrorDetail?.hasSuffix("Keys it ran on: \"with space\"") == true)
    }
}

struct RedisShardPartOutcomeTests {
    @Test("An error is a refusal, a queued acknowledgement is queued, anything else ran")
    func outcomes() {
        #expect(RedisShardPartOutcome(.error("ERR x")) == .refused("ERR x"))
        #expect(RedisShardPartOutcome(.status("QUEUED")) == .queued)
        #expect(RedisShardPartOutcome(.integer(1)) == .ran)
        #expect(RedisShardPartOutcome(.status("OK")) == .ran)
        #expect(RedisShardPartOutcome(.string("QUEUED")) == .ran)
    }
}
