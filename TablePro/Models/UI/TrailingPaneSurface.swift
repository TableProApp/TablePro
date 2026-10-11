//
//  TrailingPaneSurface.swift
//  TablePro
//

import Foundation

/// What the window's trailing pane is showing.
///
/// The inspector and the assistant are peers, not facets of one another: an inspector shows the
/// attributes of the current selection, and a chat is a separate task surface that no selection
/// owns. Each keeps a command of its own, and the pane's header offers the two as the segments of
/// one picker. That picker chooses what the pane holds, the way Xcode's inspector bar does, rather
/// than rendering the selection a second way, which is what the inspector's old three-way control
/// conflated. The pane's content follows whichever of them the user chose last.
///
/// Both share one `NSSplitViewItem` and so one autosaved width. Per-surface minimum thicknesses
/// were measured and rejected: raising `minimumThickness` on a live item force-grows the pane past
/// the width the user chose and takes the difference from the content pane, which stops at its own
/// minimum rather than growing the window. A single 270pt floor for both costs nothing, because the
/// assistant is a vertical list that reads correctly at that width.
internal enum TrailingPaneSurface: String, CaseIterable, Hashable {
    case inspector
    case assistant
    /// What the agent session proposed, ran and changed. Agent mode forces it for as long as the
    /// mode is on, and never writes it over the surface the user chose for browsing.
    case agentResult

    internal var localizedTitle: String {
        switch self {
        case .inspector: String(localized: "Inspector")
        case .assistant: String(localized: "Assistant")
        case .agentResult: String(localized: "Result")
        }
    }

    /// The glyph the header's picker names a surface by. Not `sidebar.right`, which every surface
    /// used to share: that names the pane, the one thing all three have in common.
    internal var symbolName: String {
        switch self {
        case .inspector: "info.circle"
        case .assistant: "sparkles"
        case .agentResult: "checklist"
        }
    }

    /// Whether the user may choose this surface for themselves. The result pane belongs to a mode
    /// rather than to a command, so it never lands in the stored per-connection preference.
    internal var isUserSelectable: Bool {
        self != .agentResult
    }

    /// The assistant is the only surface a setting can take away, so a stored value naming it has
    /// to resolve on every read rather than only when the setting changes: the value is restored
    /// per connection without asking whether the surface still exists, and no change notification
    /// ever reaches that restore.
    internal static func resolved(_ surface: TrailingPaneSurface, isAIEnabled: Bool) -> TrailingPaneSurface {
        guard isAIEnabled else {
            return surface == .inspector ? surface : .inspector
        }
        return surface
    }
}
