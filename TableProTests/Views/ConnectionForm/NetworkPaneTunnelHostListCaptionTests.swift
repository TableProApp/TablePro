//
//  NetworkPaneTunnelHostListCaptionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct NetworkPaneTunnelHostListCaptionTests {
    private func viewModel(type: DatabaseType, fields: [String: String]) -> NetworkPaneViewModel {
        let viewModel = NetworkPaneViewModel()
        viewModel.type = type
        viewModel.additionalFieldValues = fields
        return viewModel
    }

    @Test("Redis Sentinel says Sentinel cannot run through a tunnel, not that failover is off")
    func sentinelCaption() throws {
        let caption = try #require(viewModel(
            type: .redis,
            fields: ["redisMode": "sentinel", "redisSentinelHosts": "s1.example:26379,s2.example:26379"]
        ).tunnelHostListCaption)

        #expect(!caption.localizedCaseInsensitiveContains("replica set"))
        #expect(caption.localizedCaseInsensitiveContains("Sentinel"))
    }

    @Test("Redis Sentinel is refused through a tunnel with a single node too")
    func sentinelCaptionWithOneNode() {
        let caption = viewModel(
            type: .redis,
            fields: ["redisMode": "sentinel", "redisSentinelHosts": "s1.example:26379"]
        ).tunnelHostListCaption

        #expect(caption != nil)
    }

    @Test("Redis Cluster names the first node, not a replica set")
    func clusterCaption() throws {
        let caption = try #require(viewModel(
            type: .redis,
            fields: ["redisMode": "cluster", "redisClusterHosts": "n1.example:7000,n2.example:7001"]
        ).tunnelHostListCaption)

        #expect(!caption.localizedCaseInsensitiveContains("replica set"))
        #expect(caption.localizedCaseInsensitiveContains("node"))
    }

    @Test("Redis Cluster warns with a single seed node, since the tunnel still reaches only that node")
    func clusterCaptionWithOneSeed() {
        let caption = viewModel(
            type: .redis,
            fields: ["redisMode": "cluster", "redisClusterHosts": "n1.example:7000"]
        ).tunnelHostListCaption

        #expect(caption != nil)
    }

    @Test("Kafka names the first broker, not a replica set")
    func kafkaCaption() throws {
        let caption = try #require(viewModel(
            type: .kafka,
            fields: ["kafkaBootstrapServers": "b1.example:9092,b2.example:9092"]
        ).tunnelHostListCaption)

        #expect(!caption.localizedCaseInsensitiveContains("replica set"))
        #expect(caption.localizedCaseInsensitiveContains("broker"))
    }

    @Test("MongoDB keeps its replica set caption")
    func mongoCaption() throws {
        let caption = try #require(viewModel(
            type: .mongodb,
            fields: ["mongoHosts": "a.example:27017,b.example:27017"]
        ).tunnelHostListCaption)

        #expect(caption.localizedCaseInsensitiveContains("replica set"))
    }

    @Test("A single MongoDB host and an engine without a host list get no caption")
    func noCaption() {
        #expect(viewModel(type: .mongodb, fields: ["mongoHosts": "a.example:27017"]).tunnelHostListCaption == nil)
        #expect(viewModel(type: .postgresql, fields: [:]).tunnelHostListCaption == nil)
    }
}
