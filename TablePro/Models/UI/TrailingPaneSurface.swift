//
//  TrailingPaneSurface.swift
//  TablePro
//

import Foundation

/// What the window's trailing pane is showing.
///
/// The inspector and the assistant are peers, not facets of one another: an inspector shows the
/// attributes of the current selection, and a chat is a separate task surface that no selection
/// owns. They therefore get one command each rather than two segments of one control, and the
/// pane's content follows whichever command was used last.
///
/// Both share one `NSSplitViewItem` and so one autosaved width. Per-surface minimum thicknesses
/// were measured and rejected: raising `minimumThickness` on a live item force-grows the pane past
/// the width the user chose and takes the difference from the content pane, which stops at its own
/// minimum rather than growing the window. A single 270pt floor for both costs nothing, because the
/// assistant is a vertical list that reads correctly at that width.
internal enum TrailingPaneSurface: String, CaseIterable, Hashable {
    case inspector
    case assistant

    internal var localizedTitle: String {
        switch self {
        case .inspector: String(localized: "Inspector")
        case .assistant: String(localized: "Assistant")
        }
    }

    /// The assistant is the only surface a setting can take away, so a stored value naming it has
    /// to resolve on every read rather than only when the setting changes: the value is restored
    /// per connection without asking whether the surface still exists, and no change notification
    /// ever reaches that restore.
    internal static func resolved(_ surface: TrailingPaneSurface, isAIEnabled: Bool) -> TrailingPaneSurface {
        surface == .assistant && !isAIEnabled ? .inspector : surface
    }
}
