//
//  TrailingPaneSurfaceResolver.swift
//  TablePro
//

import Foundation

/// Which surface the window's trailing pane is drawing, and which surfaces the user may pick.
///
/// The single answer, because four readings of the same question disagreed and only one of them
/// knew Agent mode imposes the result pane. Show Inspector therefore titled itself Hide Inspector
/// over a column the inspector does not own, collapsed it, and left no command that could bring it
/// back; Show Assistant persisted a browse preference the mode overrode on the next read.
internal enum TrailingPaneSurfaceResolver {
    /// The content mode is resolved first, so a window left in Agent mode with the AI setting off
    /// cannot ask for a surface the pane will never draw.
    internal static func resolve(
        stored: TrailingPaneSurface,
        contentMode: ConnectionWorkspaceContentMode,
        isAIEnabled: Bool
    ) -> TrailingPaneSurface {
        switch ConnectionWorkspaceContentMode.resolved(contentMode, isAIEnabled: isAIEnabled) {
        case .agent:
            return .agentResult
        case .browse:
            /// The result pane belongs to Agent mode, so browsing never draws it however the stored
            /// value got there. `TrailingPaneSurface.resolved` passes it through, because its own
            /// job is the AI setting rather than the mode.
            guard stored.isUserSelectable else { return .inspector }
            return TrailingPaneSurface.resolved(stored, isAIEnabled: isAIEnabled)
        }
    }

    /// What the pane's header offers. Empty in Agent mode, where the mode chose for the user, which
    /// is what makes the header draw a plain title rather than a picker with one segment in it.
    internal static func selectable(
        contentMode: ConnectionWorkspaceContentMode,
        isAIEnabled: Bool
    ) -> [TrailingPaneSurface] {
        switch ConnectionWorkspaceContentMode.resolved(contentMode, isAIEnabled: isAIEnabled) {
        case .agent:
            return []
        case .browse:
            return isAIEnabled ? [.inspector, .assistant] : [.inspector]
        }
    }
}
