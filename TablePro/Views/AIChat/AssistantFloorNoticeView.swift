//
//  AssistantFloorNoticeView.swift
//  TablePro
//

import SwiftUI

/// Says that Assistant mode is holding this connection at Confirm Writes, and that it is temporary.
///
/// A user who chose Silent on purpose is about to start getting prompts, so the surface has to say
/// what changed and that leaving the mode ends it. Without the line the mode reads as the app
/// ignoring a setting they made.
internal struct AssistantFloorNoticeView: View {
    internal let connectionId: UUID

    /// Read rather than observed. The mode is UserDefaults-backed and not `@Observable`, but every
    /// mode change rewrites the three panes' `rootView`, which remounts this view, so there is
    /// nothing for an observation to add here.
    private var isActive: Bool {
        AssistantSafeModeFloor.isActive(for: connectionId)
    }

    /// A plain inline label, with no chrome of its own.
    ///
    /// Two surfaces show it: the chat composer, where it sits inside an already-padded stack, and
    /// the result pane, which frames it as a bottom bar. Giving the notice a divider and a bar here
    /// would put both inside the composer, so the framing belongs to whichever host wants it.
    internal var body: some View {
        if isActive {
            Label(
                String(localized: "Confirm Writes while in Assistant mode"),
                systemImage: "exclamationmark.triangle"
            )
            .symbolRenderingMode(.hierarchical)
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(String(
                localized: "Assistant mode holds this connection at Confirm Writes, whatever its own Safe Mode level says. Switch to Browse to restore your level."
            ))
        }
    }
}
