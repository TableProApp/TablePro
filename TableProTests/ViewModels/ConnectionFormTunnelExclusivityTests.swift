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
        coordinator.tunnelCommand.state.enabled = enabled.contains(.tunnelCommand)
        return coordinator
    }

    @Test("no enabled tunnels yields an empty list")
    func emptyWhenAllDisabled() {
        let coordinator = coordinator(enabled: [])
        #expect(coordinator.enabledTunnels.isEmpty)
        for kind in ConnectionTunnelKind.formToggleable {
            #expect(coordinator.otherEnabledTunnels(excluding: kind).isEmpty)
        }
    }

    @Test("every pair of enabled tunnels warns in both directions")
    func pairwiseConflicts() {
        let kinds = ConnectionTunnelKind.formToggleable
        for first in kinds {
            for second in kinds where second != first {
                let coordinator = coordinator(enabled: [first, second])
                #expect(coordinator.otherEnabledTunnels(excluding: first).map(\.kind) == [second])
                #expect(coordinator.otherEnabledTunnels(excluding: second).map(\.kind) == [first])
            }
        }
    }

    @Test("every toggleable tunnel enabled reports all the others per kind")
    func allEnabled() {
        let coordinator = coordinator(enabled: Set(ConnectionTunnelKind.formToggleable))
        #expect(coordinator.enabledTunnels.count == ConnectionTunnelKind.formToggleable.count)
        for kind in ConnectionTunnelKind.formToggleable {
            let others = coordinator.otherEnabledTunnels(excluding: kind)
            #expect(others.count == ConnectionTunnelKind.formToggleable.count - 1)
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
        let coordinator = coordinator(enabled: Set(ConnectionTunnelKind.formToggleable))
        coordinator.socksProxy.state.host = "proxy.example.com"
        coordinator.cloudflareTunnel.state.accessHostname = "db.example.com"
        coordinator.cloudSQLProxy.state.instanceConnectionName = "p:r:i"
        coordinator.ssh.state.host = "bastion.example.com"
        coordinator.tunnelCommand.state.config.kubernetesResource = "service/postgres"

        let others = ConnectionTunnelKind.formToggleable.count - 1
        #expect(coordinator.ssh.validationIssues.count >= others)
        #expect(coordinator.cloudflareTunnel.validationIssues.count >= others)
        #expect(coordinator.cloudSQLProxy.validationIssues.count >= others)
        #expect(coordinator.socksProxy.validationIssues.count >= others)
        #expect(coordinator.tunnelCommand.validationIssues.count >= others)
    }
}
