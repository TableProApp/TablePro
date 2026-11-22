//
//  ConnectionFormDisclosureStateTests.swift
//  TableProTests
//
//  The connection form opens with only General visible and the rest behind disclosures. These
//  cover the coordinator signals the form reads to open the sections a connection already uses.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionFormDisclosureStateTests {
    private func coordinator(type: DatabaseType = .mysql) -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.type = type
        return coordinator
    }

    @Test("a plain connection reports no configured network")
    func directIsNotConfigured() {
        #expect(coordinator().networkIsConfigured == false)
    }

    @Test("a transport opens the Network section")
    func transportIsConfigured() {
        let coordinator = coordinator()
        coordinator.transport = .ssh
        #expect(coordinator.networkIsConfigured)
        #expect(coordinator.networkSummary.contains(ConnectionTunnelKind.ssh.displayName))
    }

    @Test("a client certificate opens the Network section")
    func clientCertIsConfigured() {
        let coordinator = coordinator()
        coordinator.ssl.clientCertPath = "/tmp/client.crt"
        #expect(coordinator.networkIsConfigured)
    }

    @Test("a direct connection summary does not name a tunnel")
    func directSummaryHasNoTunnel() {
        let summary = coordinator().networkSummary
        #expect(summary.contains(ConnectionTunnelKind.ssh.displayName) == false)
    }

    @Test("a plain connection is not customized")
    func defaultAppearanceIsNotCustomized() {
        #expect(coordinator().appearanceIsCustomized == false)
    }

    @Test("a chosen icon opens the Appearance section")
    func iconIsCustomized() {
        let coordinator = coordinator()
        coordinator.customization.iconName = "star.fill"
        #expect(coordinator.appearanceIsCustomized)
    }
}
