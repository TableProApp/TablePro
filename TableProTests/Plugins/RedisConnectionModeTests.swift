//
//  RedisConnectionModeTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("Redis connection mode")
struct RedisConnectionModeTests {
    @Test("An unset mode is standalone, so an existing connection keeps working")
    func defaultsToStandalone() {
        #expect(RedisConnectionMode.resolve(additionalFields: [:]) == .standalone)
        #expect(RedisConnectionMode.resolve(additionalFields: ["redisMode": ""]) == .standalone)
    }

    @Test("Each mode round-trips through its stored value")
    func parsesEachMode() {
        #expect(RedisConnectionMode.resolve(additionalFields: ["redisMode": "sentinel"]) == .sentinel)
        #expect(RedisConnectionMode.resolve(additionalFields: ["redisMode": "cluster"]) == .cluster)
        #expect(RedisConnectionMode.resolve(additionalFields: ["redisMode": "standalone"]) == .standalone)
    }

    @Test("An unrecognised value falls back to standalone rather than failing to connect")
    func unknownFallsBack() {
        #expect(RedisConnectionMode.resolve(additionalFields: ["redisMode": "galaxy"]) == .standalone)
    }

    @Test("Only cluster gives up database selection")
    func databaseSelection() {
        #expect(RedisConnectionMode.standalone.supportsDatabaseSelection)
        #expect(RedisConnectionMode.sentinel.supportsDatabaseSelection)
        #expect(!RedisConnectionMode.cluster.supportsDatabaseSelection)
    }

    @Test("Only standalone uses the plain Host and Port fields")
    func hostListUsage() {
        #expect(!RedisConnectionMode.standalone.usesHostList)
        #expect(RedisConnectionMode.sentinel.usesHostList)
        #expect(RedisConnectionMode.cluster.usesHostList)
    }
}

@Suite("Redis host list parsing")
struct RedisHostListParserTests {
    @Test("A comma-separated list becomes one address per entry")
    func parsesList() {
        let parsed = RedisHostListParser.parse("10.0.0.1:26379, 10.0.0.2:26379", defaultPort: 26_379)
        #expect(parsed == [
            RedisNodeAddress(host: "10.0.0.1", port: 26_379),
            RedisNodeAddress(host: "10.0.0.2", port: 26_379),
        ])
    }

    @Test("An entry with no port takes the field's default")
    func appliesDefaultPort() {
        #expect(RedisHostListParser.parse("redis.internal", defaultPort: 26_379)
            == [RedisNodeAddress(host: "redis.internal", port: 26_379)])
    }

    @Test("A bracketed IPv6 literal keeps its address and reads its port")
    func parsesBracketedIPv6() {
        #expect(RedisHostListParser.parse("[fe80::1]:6380", defaultPort: 6_379)
            == [RedisNodeAddress(host: "fe80::1", port: 6_380)])
    }

    @Test("A bracketed IPv6 literal with no port takes the default")
    func parsesBracketedIPv6WithoutPort() {
        #expect(RedisHostListParser.parse("[::1]", defaultPort: 6_379)
            == [RedisNodeAddress(host: "::1", port: 6_379)])
    }

    @Test("A bare IPv6 literal is not mistaken for host:port")
    func parsesBareIPv6() {
        #expect(RedisHostListParser.parse("fe80::1", defaultPort: 6_379)
            == [RedisNodeAddress(host: "fe80::1", port: 6_379)])
    }

    @Test("Blank entries are skipped rather than becoming empty hosts")
    func skipsBlanks() {
        #expect(RedisHostListParser.parse("10.0.0.1:26379,,  ,", defaultPort: 26_379).count == 1)
    }

    @Test("An out-of-range port is rejected")
    func rejectsBadPort() {
        #expect(RedisHostListParser.parse("10.0.0.1:70000", defaultPort: 26_379).isEmpty)
        #expect(RedisHostListParser.parse("10.0.0.1:0", defaultPort: 26_379).isEmpty)
    }

    @Test("An empty list yields no addresses")
    func emptyYieldsNothing() {
        #expect(RedisHostListParser.parse("", defaultPort: 26_379).isEmpty)
    }
}

@Suite("Redis server info")
struct RedisServerInfoTests {
    private let clusterInfo = "# Server\r\nredis_version:8.10.1\r\nredis_mode:cluster\r\n"
    private let sentinelInfo = "# Server\r\nredis_version:8.10.1\r\nredis_mode:sentinel\r\n"

    @Test("Reads the version")
    func readsVersion() {
        #expect(RedisServerInfo.version(from: clusterInfo) == "8.10.1")
    }

    @Test("Reads the server mode, which is how a mode mismatch is spotted")
    func readsMode() {
        #expect(RedisServerInfo.mode(from: clusterInfo) == .cluster)
        #expect(RedisServerInfo.mode(from: sentinelInfo) == .sentinel)
        #expect(RedisServerInfo.mode(from: "redis_mode:standalone") == .standalone)
    }

    @Test("An absent key is absent, not a wrong answer")
    func missingKeyIsNil() {
        #expect(RedisServerInfo.mode(from: "# Server\r\n") == nil)
        #expect(RedisServerInfo.version(from: "") == nil)
    }

    @Test("Reads a database's key count out of INFO keyspace")
    func readsKeyCount() {
        let info = "# Keyspace\r\ndb0:keys=100,expires=0,avg_ttl=0\r\ndb3:keys=7,expires=1\r\n"
        #expect(RedisServerInfo.keyCount(forDatabase: "db0", in: info) == 100)
        #expect(RedisServerInfo.keyCount(forDatabase: "db3", in: info) == 7)
        #expect(RedisServerInfo.keyCount(forDatabase: "db9", in: info) == nil)
    }
}

@Suite("Redis topology diagnostics")
struct RedisTopologyDiagnosticsTests {
    @Test("Standalone pointed at a cluster member says to switch to Cluster")
    func standaloneAtCluster() throws {
        let message = try #require(RedisTopologyDiagnostics.mismatch(expected: .standalone, actual: .cluster))
        #expect(message.contains("Cluster"))
    }

    @Test("A data mode pointed at a Sentinel says to switch to Sentinel")
    func dataModeAtSentinel() throws {
        #expect(RedisTopologyDiagnostics.mismatch(expected: .standalone, actual: .sentinel) != nil)
        let message = try #require(RedisTopologyDiagnostics.mismatch(expected: .cluster, actual: .sentinel))
        #expect(message.contains("Sentinel"))
    }

    @Test("Cluster pointed at a standalone server says so")
    func clusterAtStandalone() throws {
        let message = try #require(RedisTopologyDiagnostics.mismatch(expected: .cluster, actual: .standalone))
        #expect(message.contains("cluster mode"))
    }

    /// A tunnel forwards one address and rewrites the mode to Standalone, so a Sentinel connection
    /// lands on a Sentinel. Telling the user to choose Sentinel mode would repeat what they did.
    @Test("Sentinel through a tunnel explains the tunnel, not the mode")
    func sentinelThroughTunnel() throws {
        let message = try #require(
            RedisTopologyDiagnostics.mismatch(expected: .standalone, actual: .sentinel, isTunneled: true)
        )
        #expect(message == RedisTopologyDiagnostics.sentinelThroughTunnelMessage)
        #expect(!message.contains("Set Connection Mode to Sentinel"))
    }

    @Test("A cluster seed through a tunnel is left alone, because it is a data node")
    func clusterThroughTunnelIsFine() {
        #expect(RedisTopologyDiagnostics.mismatch(expected: .standalone, actual: .standalone, isTunneled: true) == nil)
    }

    @Test("A matching mode reports nothing")
    func matchingModesAreSilent() {
        #expect(RedisTopologyDiagnostics.mismatch(expected: .standalone, actual: .standalone) == nil)
        #expect(RedisTopologyDiagnostics.mismatch(expected: .cluster, actual: .cluster) == nil)
    }

    @Test("Sentinel resolving to a standalone node is the expected outcome, not a mismatch")
    func sentinelResolvingToDataNodeIsFine() {
        #expect(RedisTopologyDiagnostics.mismatch(expected: .sentinel, actual: .standalone) == nil)
    }
}
