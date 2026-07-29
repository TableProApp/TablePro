//
//  DatabaseConnection+CloudSQLProxy.swift
//  TablePro
//

extension DatabaseConnection {
    var isCloudSQLProxyEnabled: Bool {
        if case .inline = cloudSQLProxyMode { return true }
        return false
    }

    var resolvedCloudSQLProxyConfig: CloudSQLProxyConfiguration? {
        if case .inline(let config) = cloudSQLProxyMode { return config }
        return nil
    }
}
