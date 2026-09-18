//
//  DatabaseConnection+TunnelCommand.swift
//  TablePro
//

extension DatabaseConnection {
    var isTunnelCommandEnabled: Bool {
        if case .inline = tunnelCommandMode { return true }
        return false
    }

    var resolvedTunnelCommandConfig: TunnelCommandConfiguration? {
        if case .inline(let config) = tunnelCommandMode { return config }
        return nil
    }
}
