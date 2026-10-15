//
//  ChatComposerDraft.swift
//  TablePro
//

import Combine
import SwiftUI

/// The text in the chat composer, published on its own rather than by `AIChatViewModel`.
///
/// Everything that shows the conversation observes the view model: the transcript, the pane around it, the agent
/// session and its rail. A keystroke published there redrew all of them; published here it redraws the field and
/// the send button.
@MainActor
internal final class ChatComposerDraft: ObservableObject {
    @Published internal var text: String = ""
}

/// Hands the draft's text to a view built for it, so that view is the only one a keystroke redraws.
internal struct ChatComposerDraftReader<Content: View>: View {
    @ObservedObject internal var draft: ChatComposerDraft
    @ViewBuilder internal let content: (Binding<String>) -> Content

    internal var body: some View {
        content($draft.text)
    }
}
