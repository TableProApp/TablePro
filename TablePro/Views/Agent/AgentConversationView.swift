//
//  AgentConversationView.swift
//  TablePro
//

import SwiftUI

/// The detail pane's content in assistant mode: the conversation at the window's full width.
///
/// It hosts the same `AIChatPanelView` the inspector does, against the same session, so the two
/// surfaces are one conversation rather than two. The inspector's tab picker, history menu and
/// new-conversation button belong to `UnifiedRightPanelView` and stay there; the session rail owns
/// those actions on this surface.
///
/// Nothing here is released in `onDisappear`. Switching connection unparents this pane and SwiftUI
/// reports that as a disappear, so anything given up there would be gone for good (#2236).
internal struct AgentConversationView: View {
    internal let connection: DatabaseConnection
    internal let currentQuery: String?
    internal let queryResults: String?
    internal let session: AgentSession

    internal var body: some View {
        AIChatPanelView(
            connection: connection,
            currentQuery: currentQuery,
            queryResults: queryResults,
            viewModel: session.viewModel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        /// A session restored from disk carries a conversation id and no turns. Pulling them in here
        /// rather than at launch means a session nobody opens never costs a read, and re-entering a
        /// session that already has its turns is a no-op.
        .task(id: session.id) {
            await AgentSessionRegistry.shared.loadTranscript(for: session)
        }
    }
}
