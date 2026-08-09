//
//  ConnectionWindowPaneResolver.swift
//  TablePro
//

import Foundation

internal enum ConnectionWindowPane: Equatable {
    case connecting
    case unavailable(ConnectionUnavailableReason)
    case content
    case empty
}

internal enum ConnectionWindowPaneResolver {
    internal static func pane(
        phase: ConnectionWindowPhase,
        hasConnection: Bool,
        hasRenderableSession: Bool
    ) -> ConnectionWindowPane {
        switch phase {
        case .closing:
            return .empty
        case .connected:
            return hasRenderableSession ? .content : .empty
        case .idle:
            if hasRenderableSession { return .content }
            return hasConnection ? .unavailable(.notConnected) : .empty
        case .connecting:
            return hasConnection ? .connecting : .empty
        case .unavailable(let reason):
            return hasConnection ? .unavailable(reason) : .empty
        }
    }
}
