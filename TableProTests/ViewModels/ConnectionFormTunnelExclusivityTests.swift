//
//  ConnectionFormTunnelExclusivityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("Connection form tunnel exclusivity")
struct ConnectionFormTunnelExclusivityTests {
    private func coordinator(enabled: Set<ConnectionTunnelKind>) -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.ssh.state.enabled = enabled.contains(.ssh)
        coordinator.cloudflareTunnel.state.enabled = enabled.contains(.cloudflare)
        coordinator.cloudSQLProxy.state.enabled = enabled.contains(.cloudSQLProxy)
        coordinator.socksProxy.state.enabled = enabled.contains(.socksProxy)
        return coordinator
    }

    @Test("no enabled tunnels yields an empty list")
    func emptyWhenAllDisabled() {
        let coordinator = coordinator(enabled: [])
        #expect(coordinator.enabledTunnels.isEmpty)
        for kind in ConnectionTunnelKind.allCases {
            #expect(coordinator.otherEnabledTunnels(excluding: kind).isEmpty)
        }
    }

    @Test("every pair of enabled tunnels warns in both directions")
    func pairwiseConflicts() {
        let kinds = ConnectionTunnelKind.allCases
        for first in kinds {
            for second in kinds where second != first {
                let coordinator = coordinator(enabled: [first, second])
                #expect(coordinator.otherEnabledTunnels(excluding: first).map(\.kind) == [second])
                #expect(coordinator.otherEnabledTunnels(excluding: second).map(\.kind) == [first])
            }
        }
    }

    @Test("all four enabled reports the three others per kind")
    func allEnabled() {
        let coordinator = coordinator(enabled: Set(ConnectionTunnelKind.allCases))
        #expect(coordinator.enabledTunnels.count == 4)
        for kind in ConnectionTunnelKind.allCases {
            let others = coordinator.otherEnabledTunnels(excluding: kind)
            #expect(others.count == 3)
            #expect(!others.map(\.kind).contains(kind))
        }
    }

    @Test("the disable action turns the other tunnel off")
    func disableAction() {
        let coordinator = coordinator(enabled: [.ssh, .socksProxy])
        let others = coordinator.otherEnabledTunnels(excluding: .socksProxy)
        #expect(others.map(\.kind) == [.ssh])
        others.first?.disable()
        #expect(!coordinator.ssh.state.enabled)
        #expect(coordinator.otherEnabledTunnels(excluding: .socksProxy).isEmpty)
    }

    @Test("each pane view model reports cross-tunnel conflicts")
    func paneViewModelsReportConflicts() {
        let coordinator = coordinator(enabled: [.ssh, .cloudflare, .cloudSQLProxy, .socksProxy])
        coordinator.socksProxy.state.host = "proxy.example.com"
        coordinator.cloudflareTunnel.state.accessHostname = "db.example.com"
        coordinator.cloudSQLProxy.state.instanceConnectionName = "p:r:i"
        coordinator.ssh.state.host = "bastion.example.com"

        #expect(coordinator.ssh.validationIssues.count >= 3)
        #expect(coordinator.cloudflareTunnel.validationIssues.count >= 3)
        #expect(coordinator.cloudSQLProxy.validationIssues.count >= 3)
        #expect(coordinator.socksProxy.validationIssues.count >= 3)
    }
}
