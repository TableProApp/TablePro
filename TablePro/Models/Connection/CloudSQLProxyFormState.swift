//
//  CloudSQLProxyFormState.swift
//  TablePro
//

import Foundation

struct CloudSQLProxyFormState {
    var enabled: Bool = false
    var instanceConnectionName: String = ""
    var authMode: CloudSQLProxyAuthMode = .applicationDefault
    var serviceAccountKeyJSON: String = ""
    var useIAMAuth: Bool = false
    var usePrivateIP: Bool = false
    var automaticPort: Bool = true
    var localPort: String = ""
    var binaryPath: String = ""

    func buildConfig() -> CloudSQLProxyConfiguration {
        CloudSQLProxyConfiguration(
            instanceConnectionName: instanceConnectionName.trimmingCharacters(in: .whitespacesAndNewlines),
            authMode: authMode,
            useIAMAuth: useIAMAuth,
            usePrivateIP: usePrivateIP,
            localPort: automaticPort ? nil : Int(localPort),
            binaryPath: binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func buildTunnelMode() -> CloudSQLProxyMode {
        enabled ? .inline(buildConfig()) : .disabled
    }

    mutating func load(from connection: DatabaseConnection) {
        switch connection.cloudSQLProxyMode {
        case .disabled:
            enabled = false
        case .inline(let config):
            enabled = true
            populateFields(from: config)
        }
    }

    mutating func populateFields(from config: CloudSQLProxyConfiguration) {
        instanceConnectionName = config.instanceConnectionName
        authMode = config.authMode
        useIAMAuth = config.useIAMAuth
        usePrivateIP = config.usePrivateIP
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
