//
//  TunnelCommandPreviewTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct TunnelCommandPreviewTests {
    private func coordinator(type: DatabaseType) -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.type = type
        coordinator.transport = .tunnelCommand
        return coordinator
    }

    @Test("A cleared Port previews the engine's default port, which is what connects")
    func clearedPortPreviewsDefaultPort() throws {
        let coordinator = coordinator(type: .postgresql)
        coordinator.tunnelCommand.state.config.method = .kubectl
        coordinator.tunnelCommand.state.config.kubernetesResource = "service/postgres"
        coordinator.network.port = ""

        let preview = try #require(coordinator.tunnelCommandPreview)

        #expect(preview.contains("{port}:5432"))
        #expect(!preview.contains(":0"))
    }

    @Test("A host-list connection previews the first listed node, which is what connects")
    func hostListPreviewsFirstListedNode() throws {
        let coordinator = coordinator(type: .redis)
        coordinator.network.host = ""
        coordinator.network.additionalFieldValues["redisMode"] = "cluster"
        coordinator.network.additionalFieldValues["redisClusterHosts"] = "a.example:7000,b.example:7001"
        coordinator.tunnelCommand.state.config.method = .custom
        coordinator.tunnelCommand.state.config.command = "forward {port} {host}:{remotePort}"

        let preview = try #require(coordinator.tunnelCommandPreview)

        #expect(preview == "forward {port} a.example:7000")
    }
}
