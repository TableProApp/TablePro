//
//  SOCKSProxyFormState.swift
//  TablePro
//

import Foundation

struct SOCKSProxyFormState {
    var enabled: Bool = false
    var host: String = ""
    var port: String = "1080"
    var username: String = ""
    var password: String = ""

    func buildConfig() -> SOCKSProxyConfiguration {
        SOCKSProxyConfiguration(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1_080,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func buildTunnelMode() -> SOCKSProxyMode {
        enabled ? .inline(buildConfig()) : .disabled
    }

    mutating func load(from connection: DatabaseConnection) {
        switch connection.socksProxyMode {
        case .disabled:
            enabled = false
        case .inline(let config):
            enabled = true
            host = config.host
            port = String(config.port)
            username = config.username
        }
    }
}
