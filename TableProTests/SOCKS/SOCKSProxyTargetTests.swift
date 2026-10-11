//
//  SOCKSProxyTargetTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct SOCKSProxyTargetTests {
    private func dialedTarget(for connection: DatabaseConnection) async throws -> FakeSOCKS5Server.ConnectRequest {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        defer { server.stop() }

        var proxied = connection
        proxied.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "127.0.0.1", port: server.port))

        _ = try await DatabaseManager.shared.buildSOCKSProxyEffectiveConnection(
            for: proxied,
            deadline: ConnectionDeadline(configuredSeconds: nil)
        )
        try await SOCKSProxyManager.shared.closeTunnel(connectionId: proxied.id)

        return try #require(server.capturedConnectRequest)
    }

    @Test("A host-list connection dials its first listed node, not the hidden Host")
    func hostListConnectionDialsFirstListedNode() async throws {
        let connection = DatabaseConnection(
            name: "cluster",
            host: "stale.example",
            port: 6_379,
            type: .redis,
            additionalFields: [
                "redisMode": "cluster",
                "redisClusterHosts": "a.example:7000,b.example:7001"
            ]
        )

        let request = try await dialedTarget(for: connection)

        #expect(request.address == Data("a.example".utf8))
        #expect(request.port == 7_000)
        #expect(connection.tunnelForwardEndpoint.host == "a.example")
        #expect(connection.tunnelForwardEndpoint.port == 7_000)
    }

    @Test("A connection without a host list dials its Host and Port")
    func singleHostConnectionDialsHostAndPort() async throws {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal.example",
            port: 5_432,
            type: .postgresql
        )

        let request = try await dialedTarget(for: connection)

        #expect(request.address == Data("db.internal.example".utf8))
        #expect(request.port == 5_432)
    }
}
