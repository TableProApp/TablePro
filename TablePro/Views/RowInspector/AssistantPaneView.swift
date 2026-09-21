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

    @State private var showsClearConfirmation = false

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
        .alert(
            String(localized: "Clear All Conversations?"),
            isPresented: $showsClearConfirmation
        ) {
            Button(String(localized: "Clear"), role: .destructive) {
                state.viewModelIfActivated?.clearConversation()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This will permanently delete all conversation history."))
        }
    }

    @ViewBuilder
    private func menuSection(_ section: TrailingPaneMenuSection) -> some View {
        switch section {
        case .conversations:
            Button {
                state.viewModelIfActivated?.startNewConversation()
            } label: {
                Label(String(localized: "New Conversation"), systemImage: "square.and.pencil")
            }
            .disabled(state.viewModelIfActivated == nil)
            conversationHistory
        case .clearRecents:
            /// Asks first: the alert is what stands between this item and every stored conversation.
            Button(role: .destructive) {
                showsClearConfirmation = true
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

    private var activeConversation: Binding<UUID?> {
        Binding(
            get: { state.viewModelIfActivated?.activeConversationID },
            set: { id in
                guard let id else { return }
                state.viewModelIfActivated?.switchConversation(to: id)
            }
        )
    }
}
