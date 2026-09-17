//
//  ConnectionWorkspaceContentMode.swift
//  TablePro
//

import Foundation

/// What a connection's window is for right now: browsing its objects, or working with an agent.
///
/// Orthogonal to `ConnectionWindowPhase`, which answers whether there is a live session to show at
/// all. Folding the mode into that enum would multiply every arm of a pure, exhaustive state
/// machine by a concern none of its transitions reason about, and the pane resolver's own header
/// records why the window's shape must not become a function of the pane.
///
/// It sits beside `phase` on `ConnectionWorkspace` for the same reason `TrailingPaneSurface` sits
/// beside it: both say which of several renderings the window is currently drawing, and neither
/// changes what the connection is doing.
internal enum ConnectionWorkspaceContentMode: String, CaseIterable, Hashable, Sendable {
    /// The object browser, the editor tabs and the trailing pane.
    case browse
    /// One agent session across the whole window: its siblings, its conversation, and what it did.
    case agent

    internal var localizedTitle: String {
        switch self {
        case .browse: String(localized: "Browse")
        case .agent: String(localized: "Agent")
        }
    }

    internal var symbolName: String {
        switch self {
        case .browse: "tablecells"
        case .agent: "sparkles"
        }
    }

    internal var toggled: ConnectionWorkspaceContentMode {
        self == .browse ? .agent : .browse
    }

    /// Agent mode is the AI feature, so it cannot stand when the feature is off. A window left in it
    /// resolves back to browsing rather than showing a surface the setting has taken away.
    internal static func resolved(
        _ mode: ConnectionWorkspaceContentMode,
        isAIEnabled: Bool
    ) -> ConnectionWorkspaceContentMode {
        mode == .agent && !isAIEnabled ? .browse : mode
    }
}
