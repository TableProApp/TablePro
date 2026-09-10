//
//  ConnectionWindowPaneResolver.swift
//  TablePro
//

import Foundation

/// What the window puts in its detail pane for one connection, and nothing else.
///
/// The window's own shape is deliberately not a function of this. It used to be: a `hidesChrome`
/// arm collapsed the sidebar and the inspector for every pane with no session behind it, so a
/// connect slower than half a second made the window rebuild itself twice, once on the way into
/// the wait and once on the way out. Measured on a PostgreSQL connection reached through an SSH
/// jump host: a blank window for 0.5s, a collapsed-chrome progress screen for 1.0s, then the
/// chrome back with the toolbar's twelve items arriving at once. The HIG asks for the opposite of
/// all three, and Console and Music both open on a full sidebar and toolbar with the content area
/// empty.
internal enum ConnectionWindowPane: Equatable {
    case connecting
    case unavailable(ConnectionUnavailableReason)
    case content
    case empty

    /// Whether a session is behind this pane. The rail reads it, because a connection with nothing
    /// to show is a connection whose object browser and tab strip name nothing, and the strip is
    /// then the only thing on screen pointing at the others the window holds.
    internal var hasContent: Bool {
        self == .content
    }
}

internal enum ConnectionWindowPaneResolver {
    /// `awaitsAutoConnect` is the window's own intent to dial, known at the moment the workspace is
    /// built, so it is answered as `.connecting` rather than as "not connected yet". The distinction
    /// used to be drawn by a timer: `.idle` reported nothing for half a second and fell back to
    /// `.notConnected` if a dial never started. A state reached by a timeout is a state nothing
    /// transitions into, so `startActivationConnectIfNeeded` now settles every path that declines to
    /// dial, and the resolver answers from facts alone.
    internal static func pane(
        phase: ConnectionWindowPhase,
        hasConnection: Bool,
        hasRenderableSession: Bool,
        awaitsAutoConnect: Bool = false
    ) -> ConnectionWindowPane {
        switch phase {
        case .closing:
            return .empty
        case .connected:
            return hasRenderableSession ? .content : .empty
        case .idle:
            if hasRenderableSession { return .content }
            guard hasConnection else { return .empty }
            return awaitsAutoConnect ? .connecting : .unavailable(.notConnected)
        case .connecting:
            guard hasConnection else { return .empty }
            return .connecting
        case .unavailable(let reason):
            return hasConnection ? .unavailable(reason) : .empty
        }
    }

    /// The tab strip's band is a list of tabs, so it appears only when there is a list worth
    /// showing: content behind it, and more than one tab in it. A window with a single tab keeps
    /// the chrome it always had, which is what the system does too.
    internal static func showsTabStrip(for pane: ConnectionWindowPane, tabCount: Int) -> Bool {
        pane == .content && tabCount > 1
    }

    /// Whether the connections strip stands, given the preference that normally governs it.
    ///
    /// The preference hides a switcher the user reaches other ways: the object browser sits beside
    /// it and the tab strip runs under the toolbar. A pane with no content leaves both of those
    /// empty, so the strip is the only thing on screen naming the connections the window still has,
    /// and the preference stops applying for as long as that lasts.
    ///
    /// Closing is passed in rather than read off the pane. A window that is tearing down resolves
    /// to `empty`, but so does a workspace whose connection never resolved, and a `connected` one
    /// with no renderable session behind it, so `empty` cannot be asked which of those it is.
    /// Laying a switcher over a window that is going away and stranding a window that is not are
    /// the same mistake read from the same value.
    internal static func showsWorkspaceRail(
        preferenceEnabled: Bool,
        workspaceCount: Int,
        pane: ConnectionWindowPane,
        isClosing: Bool
    ) -> Bool {
        guard workspaceCount > 1, !isClosing else { return false }
        return preferenceEnabled || !pane.hasContent
    }
}
