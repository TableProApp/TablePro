//
//  CloudflareTunnelFormState.swift
//  TablePro
//

import Foundation

/// Encapsulates all Cloudflare tunnel UI state for the connection form.
struct CloudflareTunnelFormState {
    var enabled: Bool = false
    var accessHostname: String = ""
    var authMethod: CloudflareAuthMethod = .browserSSO
    var serviceTokenId: String = ""
    var serviceTokenSecret: String = ""
    var automaticPort: Bool = true
    var localPort: String = ""
    var exposeToLAN: Bool = false
    var binaryPath: String = ""

    // MARK: - Build Methods

    func buildConfig() -> CloudflareConfiguration {
        CloudflareConfiguration(
            accessHostname: accessHostname.trimmingCharacters(in: .whitespacesAndNewlines),
            localPort: automaticPort ? nil : Int(localPort),
            authMethod: authMethod,
            exposeToLAN: exposeToLAN,
            binaryPath: binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func buildTunnelMode() -> CloudflareTunnelMode {
        enabled ? .inline(buildConfig()) : .disabled
    }

    // MARK: - Load Methods

    mutating func load(from connection: DatabaseConnection) {
        switch connection.cloudflareTunnelMode {
        case .disabled:
            enabled = false
        case .inline(let config):
            enabled = true
            populateFields(from: config)
        }
    }

    mutating func populateFields(from config: CloudflareConfiguration) {
        accessHostname = config.accessHostname
        authMethod = config.authMethod
        exposeToLAN = config.exposeToLAN
        binaryPath = config.binaryPath
        if let port = config.localPort {
            automaticPort = false
            localPort = String(port)
        } else {
            automaticPort = true
            localPort = ""
        }
    }
}
