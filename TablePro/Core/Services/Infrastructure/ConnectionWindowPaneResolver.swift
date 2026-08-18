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

    /// A sidebar and an inspector with nothing to put in them are not chrome, they are two empty
    /// columns that promise a session the window does not have yet.
    internal static func hidesChrome(for pane: ConnectionWindowPane) -> Bool {
        switch pane {
        case .content:
            return false
        case .connecting, .unavailable, .empty:
            return true
        }
    }

    /// The tab strip's band is a list of tabs, so it appears only when there is a list worth
    /// showing: content behind it, and more than one tab in it. A window with a single tab keeps
    /// the chrome it always had, which is what the system does too.
    internal static func showsTabStrip(for pane: ConnectionWindowPane, tabCount: Int) -> Bool {
        pane == .content && tabCount > 1
    }
}
