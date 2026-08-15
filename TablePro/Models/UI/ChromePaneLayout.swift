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
internal struct ChromePaneLayout: Equatable {
    internal let isSidebarCollapsed: Bool
    internal let isInspectorCollapsed: Bool

    /// A reveal with nothing captured is the window's first, so it opens on the sidebar with the
    /// inspector closed, which is what a fresh window shows.
    internal static func toRestore(captured: ChromePaneLayout?) -> ChromePaneLayout {
        captured ?? ChromePaneLayout(isSidebarCollapsed: false, isInspectorCollapsed: true)
    }
}
