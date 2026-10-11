//
//  PortForwardCapabilityTests.swift
//  TableProTests
//
//  Weaviate, Typesense and Elasticsearch shipped without an SSH tunnel although each is a server
//  on one HTTP port, the same shape as Trino and SurrealDB, which had one. These read the curated
//  built-in table, which is what the form reads before a plugin is installed.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct PortForwardCapabilityTests {
    private var manager: PluginManager { PluginManager.shared }

    /// PGlite's socket server binds loopback on this Mac. SAP HANA's page documents a manual
    /// forward with TLS Server Name, which keeps Verify Identity that a tunnel would drop.
    private static let networkTypesWithoutPortForward: Set<String> = ["PGlite", "SAP HANA"]

    @Test("every network type offers an SSH tunnel unless it is listed with a reason")
    func networkTypesOfferSSH() {
        let declined = DatabaseType.allKnownTypes.filter { type in
            guard let snapshot = PluginMetadataRegistry.shared.snapshot(for: type),
                  snapshot.connectionMode == .network
            else { return false }
            return !snapshot.capabilities.supportsSSH
        }
        #expect(Set(declined.map(\.rawValue)) == Self.networkTypesWithoutPortForward)
    }

    @Test(
        "a self-hosted HTTP engine offers every transport that forwards a port",
        arguments: [DatabaseType.weaviate, .typesense, .elasticsearch]
    )
    func httpEnginesOfferPortForwards(type: DatabaseType) {
        #expect(manager.supportsSSH(for: type))
        #expect(manager.supportsCloudflareTunnel(for: type))
        #expect(manager.supportsSOCKSProxy(for: type))
        #expect(manager.supportsTunnelCommand(for: type))
    }

    @Test("every transport that forwards a port is offered exactly where SSH is")
    func portForwardTransportsFollowSSH() {
        for type in DatabaseType.allKnownTypes {
            let ssh = manager.supportsSSH(for: type)
            #expect(manager.supportsCloudflareTunnel(for: type) == ssh, "Cloudflare Tunnel disagrees for \(type.rawValue)")
            #expect(manager.supportsSOCKSProxy(for: type) == ssh, "SOCKS proxy disagrees for \(type.rawValue)")
            #expect(manager.supportsTunnelCommand(for: type) == ssh, "tunnel command disagrees for \(type.rawValue)")
        }
    }
}
