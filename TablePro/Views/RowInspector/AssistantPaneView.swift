//
//  AssistantPaneView.swift
//  TablePro
//

import SwiftUI

/// The assistant, in the window's trailing pane.
///
/// It used to be the third segment of the inspector's tab picker, sharing that pane's header with
/// the row being inspected. It is its own surface now, with its own title, its own conversation
/// controls and its own command, because a chat is not one of the views of a selected row.
internal struct AssistantPaneView: View {
    internal let connection: DatabaseConnection
    @Bindable internal var state: AssistantState

    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AIChatPanelView(
                connection: connection,
                currentQuery: state.context.currentQuery,
                queryResults: state.context.queryResults,
                viewModel: state.activate()
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var header: some View {
        HStack(spacing: 4) {
            Text("Assistant")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            historyMenu
            newConversationButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var newConversationButton: some View {
        Button {
            state.viewModelIfActivated?.startNewConversation()
        } label: {
            icon("square.and.pencil")
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
        .help(String(localized: "New Conversation"))
        .accessibilityLabel(String(localized: "New Conversation"))
    }

    private var historyMenu: some View {
        Menu {
            if let viewModel = state.viewModelIfActivated {
                if !viewModel.conversations.isEmpty {
                    Section(String(localized: "Recent Conversations")) {
                        ForEach(viewModel.conversations) { conversation in
                            Button {
                                viewModel.switchConversation(to: conversation.id)
                            } label: {
                                HStack {
                                    Text(conversation.title.isEmpty
                                        ? String(localized: "Untitled")
                                        : conversation.title)
                                    if conversation.id == viewModel.activeConversationID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Label(String(localized: "Clear Recents"), systemImage: "trash")
                }
                .disabled(viewModel.conversations.isEmpty)
            }
        } label: {
            icon("clock")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
        .help(String(localized: "Conversation history"))
        .accessibilityLabel(String(localized: "Conversation history"))
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.subheadline)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
