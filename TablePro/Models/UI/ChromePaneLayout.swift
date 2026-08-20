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
internal struct ChromePaneLayout: Equatable {
    internal let isSidebarCollapsed: Bool
    internal let isInspectorCollapsed: Bool
}
