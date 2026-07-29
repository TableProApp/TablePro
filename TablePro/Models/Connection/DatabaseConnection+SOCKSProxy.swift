//
//  DatabaseConnection+SOCKSProxy.swift
//  TablePro
//

extension DatabaseConnection {
    var isSOCKSProxyEnabled: Bool {
        if case .inline = socksProxyMode { return true }
        return false
    }

    var resolvedSOCKSProxyConfig: SOCKSProxyConfiguration? {
        if case .inline(let config) = socksProxyMode { return config }
        return nil
    }
}
