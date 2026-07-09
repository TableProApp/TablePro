//
//  ConnectionTunnelKind.swift
//  TablePro
//

import Foundation

enum ConnectionTunnelKind: String, CaseIterable, Sendable {
    case ssh
    case cloudflare
    case cloudSQLProxy

    var displayName: String {
        switch self {
        case .ssh: return String(localized: "SSH Tunnel")
        case .cloudflare: return String(localized: "Cloudflare Tunnel")
        case .cloudSQLProxy: return String(localized: "Cloud SQL Auth Proxy")
        }
    }
}

extension DatabaseConnection {
    var enabledTunnelKinds: [ConnectionTunnelKind] {
        var kinds: [ConnectionTunnelKind] = []
        if resolvedSSHConfig.enabled { kinds.append(.ssh) }
        if isCloudflareEnabled { kinds.append(.cloudflare) }
        if isCloudSQLProxyEnabled { kinds.append(.cloudSQLProxy) }
        return kinds
    }

    var activeTunnelKind: ConnectionTunnelKind? {
        enabledTunnelKinds.count == 1 ? enabledTunnelKinds.first : nil
    }
}
