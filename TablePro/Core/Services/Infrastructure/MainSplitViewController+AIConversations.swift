//
//  MainSplitViewController+AIConversations.swift
//  TablePro
//

import AppKit

/// The assistant's three conversation commands, and the one place each of them is carried out.
///
/// They had no `@objc` surface at all: `AIChatViewModel` is a plain `ObservableObject` reached only
/// from SwiftUI through `AssistantState`, so New Conversation, Conversation History and Clear Recents
/// existed solely as buttons in the trailing pane's header menu. That put them out of reach of the
/// menu bar, of Settings > Keyboard, and of a user in Agent mode, where the pane draws the result
/// instead and the header menu is not there at all.
///
/// The pane header now calls these same selectors, so the two surfaces cannot drift: one place
/// decides what New Conversation does, and one place asks before Clear Recents throws anything away.
///
/// Written the way `MainSplitViewController+AgentSessions.swift` is, down to the `representedObject`
/// rule: a menu listing the conversations names one in each of its items, and every other route acts
/// on the one the assistant is showing.
internal extension MainSplitViewController {
    @objc func newAIConversation(_ sender: Any?) {
        assistantConversationModel?.startNewConversation()
    }

    @objc func switchAIConversation(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        assistantConversationModel?.switchConversation(to: id)
    }

    @objc func clearAIConversations(_ sender: Any?) {
        guard assistantConversationModel != nil else { return }
        Task { await requestClearAIConversations() }
    }

    /// Asks first: the alert is what stands between this command and every stored conversation. The
    /// model is read again after the answer, because a sheet is a wait and the connection on screen
    /// can change while it is up.
    func requestClearAIConversations() async {
        guard await confirmClearConversations(view.window) else { return }
        assistantConversationModel?.clearConversation()
    }

    /// The conversation the window's assistant commands act on: the one the connection's session
    /// holds, whichever column is drawing it. It is the same object the trailing pane's assistant
    /// resolves, so the pane's menu and the menu bar act on one conversation rather than two.
    ///
    /// Nil until something opens the assistant, which is what dims the three commands, exactly as the
    /// pane's own menu is dimmed there. Reading it starts nothing: a session is only created by
    /// revealing the surface or by a command that asks for one.
    ///
    /// Nil with the AI feature off, too. A session restored from disk outlives the setting, so
    /// without this the three commands would answer for a surface no window can draw.
    var assistantConversationModel: AIChatViewModel? {
        guard AppSettingsManager.shared.ai.enabled, let workspace = workspaces.selected else { return nil }
        return workspace.agentSessions.currentSession(for: workspace.connectionId)?.viewModel
    }
}
