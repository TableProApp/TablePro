//
//  ConnectionTunnelError.swift
//  TablePro
//

import Foundation

enum ConnectionTunnelError: Error, LocalizedError, Equatable {
    case mutualExclusivityViolation([ConnectionTunnelKind])
    case remoteFileUnsupported(String)
    case remoteFilePathMissing

    var errorDescription: String? {
        switch self {
        case .mutualExclusivityViolation(let kinds):
            let names = kinds.map(\.displayName).joined(separator: ", ")
            return String(
                format: String(localized: "A connection can use only one connection method at a time. Enabled: %@."),
                names
            )
        case .remoteFileUnsupported(let typeName):
            return String(
                format: String(localized: "%@ connections open a server, not a database file, so there is nothing to fetch over SSH."),
                typeName
            )
        case .remoteFilePathMissing:
            return String(localized: "No remote database file was named for this connection.")
        }
    }
}
