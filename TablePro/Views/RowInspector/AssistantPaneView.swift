//
//  AssistantPaneView.swift
//  TablePro
//

import SwiftUI

/// The assistant, in the window's trailing pane.
///
/// It is its own surface, with its own conversation commands and its own command in the menu bar,
/// because a chat is not one of the views of a selected row. Its commands live in the pane header's
/// menu, the same header the inspector draws, so the pane's top edge stays put when the surface
/// changes.
///
/// What it draws is the connection's session, which the registry owns rather than this view. The
/// same session is what Agent mode puts in the middle column, so the two are one conversation shown
/// two ways rather than two conversations.
internal struct AssistantPaneView: View {
    private let connection: DatabaseConnection
    @ObservedObject private var state: AssistantState
    private let paneState: TrailingPaneState
    private let contentMode: ConnectionWorkspaceContentMode

    internal init(
        connection: DatabaseConnection,
        paneState: TrailingPaneState,
        contentMode: ConnectionWorkspaceContentMode
    ) {
        self.connection = connection
        _state = ObservedObject(wrappedValue: paneState.assistant)
        self.paneState = paneState
        self.contentMode = contentMode
    }

    var body: some View {
        VStack(spacing: 0) {
            TrailingPaneHeaderView(
                surface: .assistant,
                contentMode: contentMode,
                paneState: paneState
            ) { section in
                menuSection(section)
            }
            /// Activation happens in `.task`, never in `body`. Reading it here used to mutate the
            /// observed object mid-update, which SwiftUI reports as "Publishing changes from within
            /// view updates" and answers with a second layout pass across this pane and the detail
            /// pane beside it.
            if let viewModel = state.viewModelIfActivated {
                AIChatPanelView(
                    connection: connection,
                    currentQuery: state.context.currentQuery,
                    queryResults: state.context.queryResults,
                    editorTarget: state.context.editorTarget,
                    editorSnapshot: state.editorSnapshot,
                    viewModel: viewModel
                )
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: connection.id) {
            state.activate(connection: connection)
        }
    }

    /// Every command here is sent to the window through the responder chain, exactly as File >
    /// Session sends it, rather than reaching into the view model this pane is holding. One place
    /// decides what New Conversation does and one place asks before Clear Recents throws anything
    /// away; the alert used to live in this view, so the menu bar had no way to carry the command at
    /// all without asking the question a second time in its own words.
    @ViewBuilder
    private func menuSection(_ section: TrailingPaneMenuSection) -> some View {
        switch section {
        case .conversations:
            Button {
                NSApp.sendAction(#selector(MainSplitViewController.newAIConversation(_:)), to: nil, from: nil)
            } label: {
                Label(String(localized: "New Conversation"), systemImage: "square.and.pencil")
            }
            .disabled(state.viewModelIfActivated == nil)
            conversationHistory
        case .clearRecents:
            Button(role: .destructive) {
                NSApp.sendAction(#selector(MainSplitViewController.clearAIConversations(_:)), to: nil, from: nil)
            } label: {
                Label(String(localized: "Clear Recents"), systemImage: "trash")
            }
            .disabled(conversations.isEmpty)
        case .inspectorRendering, .jsonReading, .resultView:
            EmptyView()
        }
    }

    /// A submenu, because the list grows with every conversation. The current one carries the
    /// menu's own checkmark, which VoiceOver reads as selected; it used to be a bare checkmark image
    /// beside the title that announced nothing. `text.bubble` rather than `clock`, which is Query
    /// History's glyph in the same window.
    private var conversationHistory: some View {
        Menu {
            Picker(String(localized: "Recent Conversations"), selection: activeConversation) {
                ForEach(conversations) { conversation in
                    Text(conversation.title.isEmpty ? String(localized: "Untitled") : conversation.title)
                        .tag(Optional(conversation.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(String(localized: "Conversation History"), systemImage: "text.bubble")
        }
        .disabled(conversations.isEmpty)
    }

    private var conversations: [AIConversation] {
        state.viewModelIfActivated?.conversations ?? []
    }

    /// The chosen conversation travels on an `NSMenuItem` because that is how the command names one:
    /// `switchAIConversation(_:)` reads `representedObject`, and the item is built by the same class
    /// that builds the menu bar's rows, so there is one answer to how a conversation is named to the
    /// window rather than one per surface.
    private var activeConversation: Binding<UUID?> {
        Binding(
            get: { state.viewModelIfActivated?.activeConversationID },
            set: { id in
                guard let id, let conversation = conversations.first(where: { $0.id == id }) else { return }
                let sender = ConversationHistoryMenuDelegate.item(for: conversation, isActive: false)
                NSApp.sendAction(ConversationHistoryMenuDelegate.action, to: nil, from: sender)
            }
        )
    }
}
