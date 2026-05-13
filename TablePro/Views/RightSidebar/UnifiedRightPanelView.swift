//
//  UnifiedRightPanelView.swift
//  TablePro
//

import SwiftUI

struct UnifiedRightPanelView: View {
    @Bindable var state: RightPanelState
    let connection: DatabaseConnection

    private let settingsManager = AppSettingsManager.shared
    @State private var showClearConfirmation = false

    var body: some View {
        Group {
            if settingsManager.ai.enabled {
                splitContent
            } else {
                detailsView
            }
        }
        .onChange(of: settingsManager.ai.enabled) {
            if !settingsManager.ai.enabled {
                state.activeTab = .details
            }
        }
        .alert(
            String(localized: "Clear All Conversations?"),
            isPresented: $showClearConfirmation
        ) {
            Button(String(localized: "Clear"), role: .destructive) {
                state.aiViewModel.clearConversation()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This will permanently delete all conversation history."))
        }
    }

    private var splitContent: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            switch state.activeTab {
            case .details: detailsView
            case .aiChat:  aiChatView
            }
        }
    }

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 4) {
            tabPicker
            Spacer(minLength: 8)
            if state.activeTab == .aiChat {
                historyMenu
                newConversationButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tabPicker: some View {
        Picker("", selection: $state.activeTab) {
            ForEach(RightPanelTab.allCases, id: \.self) { tab in
                Text(tab.localizedTitle).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var newConversationButton: some View {
        Button {
            state.aiViewModel.startNewConversation()
        } label: {
            inspectorIcon("square.and.pencil")
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
        .help(String(localized: "New Conversation"))
    }

    private var historyMenu: some View {
        Menu {
            let viewModel = state.aiViewModel
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
                showClearConfirmation = true
            } label: {
                Label(String(localized: "Clear Recents"), systemImage: "trash")
            }
            .disabled(viewModel.conversations.isEmpty)
        } label: {
            inspectorIcon("clock")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
        .help(String(localized: "Conversation history"))
    }

    private func inspectorIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.subheadline)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailsView: some View {
        let ctx = state.inspectorContext
        return RightSidebarView(
            tableName: ctx.tableName,
            tableMetadata: ctx.tableMetadata,
            selectedRowData: ctx.selectedRowData,
            isEditable: ctx.isEditable,
            isRowDeleted: ctx.isRowDeleted,
            editState: state.editState,
            databaseType: connection.type
        )
    }

    private var aiChatView: some View {
        let ctx = state.inspectorContext
        return AIChatPanelView(
            connection: connection,
            currentQuery: ctx.currentQuery,
            queryResults: ctx.queryResults,
            viewModel: state.aiViewModel
        )
    }
}
