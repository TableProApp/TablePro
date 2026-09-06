//
//  ChromePaneLayout.swift
//  TablePro
//

import Foundation

/// Which of the window's side panes the user had open.
///
/// A phase the user did not choose, a connection dropping or a switch to a workspace that is still
/// connecting, collapses both panes and switches autosaving off so the collapse is never written
/// down as their layout. That leaves the reveal with nothing to read back, because AppKit does not
/// re-apply an autosave record to a split view that has already laid out. This is what the reveal
/// reads instead.
///
/// A window that never hid its chrome has none of this: its panes are already where the autosaved
/// layout put them, so the reveal leaves them alone rather than restoring a default over them.
/// This records the window's geometry and nothing about which connection was on screen.
///
/// Which surface the trailing pane shows belongs to the workspace, which persists it per
/// connection, so the reveal mounts what the selected workspace already owns rather than putting
/// back a value captured while a different connection was selected. Carrying the surface here
/// wrote one connection's choice onto another: the reveal runs after `showSelectedPanes()`, so a
/// hide under connection A and a reveal under connection B assigned A's surface to B and persisted
/// it under B's id.
internal struct ChromePaneLayout: Equatable {
    internal let isSidebarCollapsed: Bool
    internal let isTrailingPaneCollapsed: Bool
}
