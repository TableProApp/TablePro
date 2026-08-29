//
//  WorkspacePanes.swift
//  TablePro
//

import AppKit
import SwiftUI

/// What a workspace's cached panes were last built from.
///
/// The panes are a rendering of the workspace's resolved pane, and a rendering is only correct for
/// the state it was made from. Recording that state is what lets a repaint be asked for from
/// anywhere and cost nothing when nothing has moved, which is what makes it safe to ask on every
/// workspace switch. Repainting unconditionally there would re-evaluate the whole content tree on
/// each switch and give back exactly the work `WorkspacePanes` exists to avoid.
///
/// It carries the connection record because a rename changes what the panes draw without changing
/// which pane they draw, and a session revision rather than the session itself because a session
/// holds the driver: keeping one here would hold a released driver alive for as long as the record.
internal struct WorkspacePaneRenderKey: Equatable {
    internal let pane: ConnectionWindowPane
    internal let connection: DatabaseConnection?
    internal let sessionRevision: Int
}

/// One connection's three panes, kept alive for as long as the window hosts that connection.
///
/// The window used to own one hosting controller per pane and reassign its `rootView` on every
/// workspace switch, which tore down and rebuilt the whole data grid, editor and object tree each
/// time. Measured at 120ms to 190ms of layout per click, none of it visible to a timer around the
/// switch itself because assigning `rootView` returns immediately and books the work for the next
/// layout pass. The cost was the pane changing under one controller, not `AnyView`: every builder
/// here erases a single `_ConditionalContent`, so the wrapped type is stable and a rewrite that
/// keeps the same branch is measurably free.
///
/// Rebuilding also destroyed everything those views own that no model holds: grid scroll position,
/// rectangular cell selection, the editor's find panel and undo stack, and an unsaved Create Table
/// definition. Keeping a connection's panes alive is a correctness fix as much as a speed one.
///
/// `sizingOptions = []` is applied here and nowhere else. It is the firewall that stops tab content
/// from publishing a minimum width the window's split dividers cannot beat (#1872); putting it on
/// the type rather than at each creation site is what makes it impossible to forget.
@MainActor
internal final class WorkspacePanes {
    internal let detail: NSHostingController<AnyView>
    internal let inspector: NSHostingController<AnyView>
    internal let sidebar: NSHostingController<AnyView>
    /// The editor tab strip. It is a pane like the other three, built and kept alive per
    /// connection, even though the window shows it in the titlebar accessory rather than in a
    /// split item. Holding it here is what gives it the same `sizingOptions` firewall and the
    /// same teardown as everything else the connection owns.
    ///
    /// It is the one pane that is not a bare hosting controller. AppKit owns the pointer over the
    /// strip, so the SwiftUI view is wrapped in the view that owns it; see
    /// `EditorTabStripPaneController`.
    internal let tabStrip: EditorTabStripPaneController

    /// Written by the one function that produces pane content, and read by the one that decides
    /// whether it has to run. `nil` means the panes hold nothing anybody has vouched for.
    internal private(set) var renderedKey: WorkspacePaneRenderKey?

    internal init() {
        detail = NSHostingController(rootView: AnyView(Color.clear))
        inspector = NSHostingController(rootView: AnyView(Color.clear))
        sidebar = NSHostingController(rootView: AnyView(Color.clear))
        tabStrip = EditorTabStripPaneController()
        for pane in panes {
            pane.sizingOptions = []
        }
    }

    private var panes: [NSHostingController<AnyView>] {
        [detail, inspector, sidebar]
    }

    internal func markRendered(_ key: WorkspacePaneRenderKey) {
        renderedKey = key
    }

    /// Drops the record without touching the views. A workspace handed to another window keeps the
    /// panes it already built, and every closure inside them calls back into the controller that
    /// built them, which is no longer the one hosting it.
    internal func invalidate() {
        renderedKey = nil
    }

    /// Empties every pane and unparents it. A hosting controller retains its SwiftUI tree, which
    /// retains the `MainContentCoordinator`, which only leaves the app-wide coordinator registry
    /// when it deinits: a pane left behind keeps a dead session answering questions about open tabs
    /// and unsaved work for the rest of the app's life.
    ///
    /// Emptying `rootView` is not enough on its own. SwiftUI reconciles a hosting controller on a
    /// layout pass, and by the time this runs the pane is detached: closing a connection removes it
    /// from the registry first, which selects a neighbour and unparents this pane. Nobody asks a
    /// detached view to lay out, so without the explicit pass the old tree stays mounted, nothing
    /// is dismantled, and the dead session this is meant to drop goes on answering the app about
    /// open tabs and unsaved work. Clearing before unparenting keeps the same true if a caller ever
    /// tears down a pane that is still on screen. A pane that was never parented has nothing
    /// mounted to drop, and the cleared `rootView` is enough for it.
    internal func teardown() {
        renderedKey = nil
        for pane in panes {
            pane.rootView = AnyView(Color.clear)
            pane.view.layoutSubtreeIfNeeded()
            pane.view.removeFromSuperview()
            pane.removeFromParent()
        }
        tabStrip.teardown()
    }
}
