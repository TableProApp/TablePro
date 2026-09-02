//
//  ConnectionWindowPaneResolver.swift
//  TablePro
//

import Foundation

internal enum ConnectionWindowPane: Equatable {
    /// A connect too young to be worth saying anything about. It draws nothing and, unlike every
    /// other contentless pane, it leaves the window's chrome alone: a local file opens in about
    /// 40ms, and collapsing the sidebar and inspector for that long only to put them back is a
    /// layout cycle nobody asked for and a flash the HIG names outright.
    case preparing
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
    /// `hasOutlastedGrace` is false for the first `LoadingRevealPolicy.grace` of a connect and of
    /// the moment before one starts. Neither is a state worth reporting: the first has not lasted
    /// long enough to be worth a word, and the second is not "not connected", it is "about to
    /// dial", a distinction `.idle` alone cannot draw because it answers for both. Measured on the
    /// SQLite sample, reporting them built three pane hierarchies and ran a whole chrome collapse
    /// and reveal inside the first 103ms of a window's life, for a 39ms connect.
    ///
    /// The grace expiring is the exit from `.preparing` in both directions, which is why `.idle`
    /// reads it too. A connect that never starts, because the phase disallowed it or the record
    /// went missing, would otherwise leave the window silently empty for good.
    internal static func pane(
        phase: ConnectionWindowPhase,
        hasConnection: Bool,
        hasRenderableSession: Bool,
        awaitsAutoConnect: Bool = false,
        hasOutlastedGrace: Bool = true
    ) -> ConnectionWindowPane {
        switch phase {
        case .closing:
            return .empty
        case .connected:
            return hasRenderableSession ? .content : .empty
        case .idle:
            if hasRenderableSession { return .content }
            guard hasConnection else { return .empty }
            guard awaitsAutoConnect, !hasOutlastedGrace else { return .unavailable(.notConnected) }
            return .preparing
        case .connecting:
            guard hasConnection else { return .empty }
            return hasOutlastedGrace ? .connecting : .preparing
        case .unavailable(let reason):
            return hasConnection ? .unavailable(reason) : .empty
        }
    }

    /// Whether this phase is one the grace timer runs over, so a caller knows when to arm it and
    /// when to let it go. It is the exact set of phases `pane` answers differently for depending
    /// on `showsProgress`, plus the pre-dial `.idle` that resolves to `.preparing` on its own.
    internal static func awaitsProgressGrace(
        phase: ConnectionWindowPhase,
        awaitsAutoConnect: Bool
    ) -> Bool {
        switch phase {
        case .connecting:
            return true
        case .idle:
            return awaitsAutoConnect
        case .connected, .closing, .unavailable:
            return false
        }
    }

    /// An object browser and an inspector with nothing to put in them are not chrome, they are two
    /// empty columns that promise a session the window does not have yet.
    ///
    /// That argument holds for a wait the user can see and not for one they cannot. `.preparing`
    /// is the sub-grace case and keeps the chrome, so the window that opens is the window that
    /// stays: on the happy path nothing collapses, nothing is put back, and the panes are built
    /// once. Collapsing for 40ms costs `splitView.autosaveName`, both split items and a
    /// `recalculateKeyViewLoop()` in each direction, all of it to show an empty column briefly.
    internal static func hidesChrome(for pane: ConnectionWindowPane) -> Bool {
        switch pane {
        case .content, .preparing:
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

    /// Whether the connections strip stands, given the preference that normally governs it.
    ///
    /// The preference hides a switcher the user reaches other ways: the object browser sits beside
    /// it, the tab strip runs under the toolbar, and Switch Connection is in the Database menu. A
    /// pane with no content takes every one of those with it, and the strip is then the only thing
    /// on screen pointing at the connections the window still has, so the preference stops applying
    /// for as long as that lasts. `railOnly` preserves a strip that is already up; without this
    /// nothing brings one back, and a user who had hidden it was left with a window whose every
    /// route out was a menu command or a keystroke.
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
        return preferenceEnabled || hidesChrome(for: pane)
    }
}
