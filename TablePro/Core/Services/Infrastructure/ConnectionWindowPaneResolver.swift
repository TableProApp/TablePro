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

/// What the window's one sidebar item holds. `railOnly` is the state that exists because the
/// workspace rail and the object browser share that item and answer to different owners.
internal enum SidebarChromeMode: Equatable {
    case revealed
    case railOnly
    case hidden

    internal var showsObjectBrowser: Bool { self == .revealed }
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

    /// An object browser and an inspector with nothing to put in them are not chrome, they are two
    /// empty columns that promise a session the window does not have yet.
    internal static func hidesChrome(for pane: ConnectionWindowPane) -> Bool {
        switch pane {
        case .content:
            return false
        case .connecting, .unavailable, .empty:
            return true
        }
    }

    /// How much of the window's sidebar survives the pane it is standing next to.
    ///
    /// The rule above is right about the object browser and wrong about the workspace rail, which
    /// lists every connection the window hosts and belongs to the window rather than to any one of
    /// them. They share a split item because AppKit grants full-height sidebar layout to exactly one
    /// leading sidebar, so collapsing for an empty object browser took the switcher with it and left
    /// the window's other connections with no way in.
    internal static func sidebarChromeMode(
        for pane: ConnectionWindowPane,
        hasRail: Bool
    ) -> SidebarChromeMode {
        guard hidesChrome(for: pane) else { return .revealed }
        return hasRail ? .railOnly : .hidden
    }

    /// The tab strip's band is a list of tabs, so it appears only when there is a list worth
    /// showing: content behind it, and more than one tab in it. A window with a single tab keeps
    /// the chrome it always had, which is what the system does too.
    internal static func showsTabStrip(for pane: ConnectionWindowPane, tabCount: Int) -> Bool {
        pane == .content && tabCount > 1
    }
}
