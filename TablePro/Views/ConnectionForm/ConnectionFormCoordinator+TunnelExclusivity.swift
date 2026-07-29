//
//  ConnectionFormCoordinator+TunnelExclusivity.swift
//  TablePro
//

import Foundation

@MainActor
extension ConnectionFormCoordinator {
    struct EnabledTunnel: Identifiable {
        let kind: ConnectionTunnelKind
        let disable: () -> Void

        var id: String { kind.rawValue }
    }

    var enabledTunnels: [EnabledTunnel] {
        var tunnels: [EnabledTunnel] = []
        if ssh.state.enabled {
            tunnels.append(EnabledTunnel(kind: .ssh) { [weak self] in self?.ssh.state.disable() })
        }
        if cloudflareTunnel.state.enabled {
            tunnels.append(EnabledTunnel(kind: .cloudflare) { [weak self] in
                self?.cloudflareTunnel.state.enabled = false
            })
        }
        if cloudSQLProxy.state.enabled {
            tunnels.append(EnabledTunnel(kind: .cloudSQLProxy) { [weak self] in
                self?.cloudSQLProxy.state.enabled = false
            })
        }
        if socksProxy.state.enabled {
            tunnels.append(EnabledTunnel(kind: .socksProxy) { [weak self] in
                self?.socksProxy.state.enabled = false
            })
        }
        return tunnels
    }

    func otherEnabledTunnels(excluding kind: ConnectionTunnelKind) -> [EnabledTunnel] {
        enabledTunnels.filter { $0.kind != kind }
    }
}
