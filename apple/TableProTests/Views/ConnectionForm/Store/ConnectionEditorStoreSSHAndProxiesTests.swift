//
//  ConnectionEditorStoreSSHAndProxiesTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreSSHAndProxiesTests {
    @Test("Redis Sentinel says Sentinel cannot run through a tunnel, even with one node")
    func sentinelAdvice() throws {
        let many = try #require(TunnelHostListAdvice.message(fieldId: "redisSentinelHosts", hosts: "s1.example:26379,s2.example:26379"))
        #expect(many.localizedCaseInsensitiveContains("Sentinel"))
        #expect(!many.localizedCaseInsensitiveContains("replica set"))
        #expect(TunnelHostListAdvice.message(fieldId: "redisSentinelHosts", hosts: "s1.example:26379") != nil)
    }

    @Test("Redis Cluster names the first node, even with one seed")
    func clusterAdvice() throws {
        let advice = try #require(TunnelHostListAdvice.message(fieldId: "redisClusterHosts", hosts: "n1.example:7000,n2.example:7001"))
        #expect(advice.localizedCaseInsensitiveContains("node"))
        #expect(TunnelHostListAdvice.message(fieldId: "redisClusterHosts", hosts: "n1.example:7000") != nil)
    }

    @Test("Kafka names the first broker and MongoDB its replica set")
    func brokerAndReplicaSetAdvice() throws {
        let kafka = try #require(TunnelHostListAdvice.message(fieldId: "kafkaBootstrapServers", hosts: "b1.example:9092,b2.example:9092"))
        #expect(kafka.localizedCaseInsensitiveContains("broker"))
        let mongo = try #require(TunnelHostListAdvice.message(fieldId: "mongoHosts", hosts: "a.example:27017,b.example:27017"))
        #expect(mongo.localizedCaseInsensitiveContains("replica set"))
    }

    @Test("A single host gets no advice")
    func singleHostHasNoAdvice() {
        #expect(TunnelHostListAdvice.message(fieldId: "mongoHosts", hosts: "a.example:27017") == nil)
        #expect(TunnelHostListAdvice.message(fieldId: "anyHosts", hosts: "a.example") == nil)
    }

    @Test("The store advises only while the SSH tunnel carries a host list")
    func storeAdvisesOnlyOverSSH() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .redis, parsedURL: nil))
        store.setFieldValue("sentinel", for: "redisMode")
        store.setFieldValue("s1.example:26379,s2.example:26379", for: "redisSentinelHosts")
        #expect(store.tunnelHostListAdvice == nil)

        store.selectTransport(.ssh)
        let advice = try #require(store.tunnelHostListAdvice)
        #expect(advice.localizedCaseInsensitiveContains("Sentinel"))

        let postgres = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        postgres.selectTransport(.ssh)
        #expect(postgres.tunnelHostListAdvice == nil)
    }
}
