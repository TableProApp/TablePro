//
//  TunnelCommandFormState.swift
//  TablePro
//

import Foundation

struct TunnelCommandFormState {
    var enabled: Bool = false
    var config = TunnelCommandConfiguration()

    func buildConfig() -> TunnelCommandConfiguration {
        var trimmed = config
        trimmed.command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.executablePath = config.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.kubernetesNamespace = config.kubernetesNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.kubernetesResource = config.kubernetesResource.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.kubernetesContext = config.kubernetesContext.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.awsTarget = config.awsTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.awsProfile = config.awsProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.awsRegion = config.awsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    func buildTunnelMode() -> TunnelCommandMode {
        enabled ? .inline(buildConfig()) : .disabled
    }

    mutating func load(from connection: DatabaseConnection) {
        switch connection.tunnelCommandMode {
        case .disabled:
            enabled = false
        case .inline(let stored):
            enabled = true
            config = stored
        }
    }
}
