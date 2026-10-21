//
//  ConnectionTimeoutPolicy+Connection.swift
//  TablePro
//

import Foundation

extension ConnectionTimeoutPolicy {
    static func effectiveQueryTimeoutSeconds(configuredSeconds: Int?, globalSeconds: Int) -> Int {
        let validatedGlobalSeconds = min(
            max(globalSeconds, DatabaseConnection.queryTimeoutSecondsRange.lowerBound),
            DatabaseConnection.queryTimeoutSecondsRange.upperBound
        )
        guard let configuredSeconds,
              DatabaseConnection.queryTimeoutSecondsRange.contains(configuredSeconds)
        else {
            return validatedGlobalSeconds
        }
        return configuredSeconds
    }

    static func requiresHostDeadline(for connection: DatabaseConnection) -> Bool {
        switch connection.type {
        case .sqlite:
            return connection.additionalFields[RemoteSQLiteWire.backendFieldKey]
                == RemoteSQLiteWire.agentBackendValue
        case .libsql, .turso:
            return connection.additionalFields["libsqlMode"] != "local"
        default:
            return true
        }
    }
}
