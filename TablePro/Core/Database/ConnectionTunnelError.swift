//
//  ConnectionTunnelError.swift
//  TablePro
//

import Foundation

enum ConnectionTunnelError: Error, LocalizedError, Equatable {
    case mutualExclusivityViolation([ConnectionTunnelKind])

    var errorDescription: String? {
        switch self {
        case .mutualExclusivityViolation(let kinds):
            let names = kinds.map(\.displayName).joined(separator: ", ")
            return String(
                format: String(localized: "A connection can use only one connection method at a time. Enabled: %@."),
                names
            )
        }
    }
}
