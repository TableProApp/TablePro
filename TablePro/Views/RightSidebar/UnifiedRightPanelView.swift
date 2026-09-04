//
//  UnifiedRightPanelView.swift
//  TablePro
//

import SwiftUI

struct UnifiedRightPanelView: View {
    @Bindable var state: RightPanelState
    let connection: DatabaseConnection

    private let settingsManager = AppSettingsManager.shared
    @Environment(\.commandActions) private var commandActions
    @State private var showClearConfirmation = false

    /// AI Chat is the only tab a setting can take away, and a tab that is gone cannot stay
    /// selected: the picker would show no selection and the panel no content.
    private var availableTabs: [RightPanelTab] {
        RightPanelTab.available(isAIEnabled: settingsManager.ai.enabled)
    }

    /// Every read of the active tab goes through the resolution, because the stored value is
    /// restored per connection without asking whether the tab still exists and no change
    /// notification fires for a value that was already wrong when the panel appeared.
    private var activeTab: RightPanelTab {
        RightPanelTab.resolved(state.activeTab, isAIEnabled: settingsManager.ai.enabled)
    }

    /// Writes the resolution back so the stored tab stops naming one the panel cannot show, and
    /// only when it differs: every assignment persists, and the panel appears on every switch.
    private func normalizeActiveTab() {
        guard state.activeTab != activeTab else { return }
        state.activeTab = activeTab
    }

    var body: some View {
        splitContent
        .task { normalizeActiveTab() }
        .onChange(of: settingsManager.ai.enabled) { normalizeActiveTab() }
        .alert(
            String(localized: "Clear All Conversations?"),
            isPresented: $showClearConfirmation
        ) {
            Button(String(localized: "Clear"), role: .destructive) {
                state.session?.viewModel.clearConversation()
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
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Details stays mounted and is hidden rather than rebuilt.
    ///
    /// Its field list is a `List`, so leaving the tab tears down an `NSTableView` and a field editor
    /// per column, and coming back builds them again: the switch cost grows with the row's width.
    /// The other two tabs are cheap to rebuild and are left conditional, which also keeps the AI
    /// chat's view model and its conversation load off a window that never opens that tab.
    private var tabContent: some View {
        ZStack(alignment: .topLeading) {
            detailsView
                .opacity(activeTab == .details ? 1 : 0)
                .allowsHitTesting(activeTab == .details)
                .disabled(activeTab != .details)
                .accessibilityHidden(activeTab != .details)

            switch activeTab {
            case .details: EmptyView()
            case .json:    jsonView
            case .aiChat:  aiChatView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 4) {
            tabPicker
            Spacer(minLength: 8)
            if activeTab == .aiChat {
                historyMenu
                newConversationButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tabPicker: some View {
        Picker("", selection: Binding(get: { activeTab }, set: { state.activeTab = $0 })) {
            ForEach(availableTabs, id: \.self) { tab in
                Text(tab.localizedTitle).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var newConversationButton: some View {
        Button {
            state.startSession()?.viewModel.startNewConversation()
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
            let viewModel = state.session?.viewModel
            if let viewModel, !viewModel.conversations.isEmpty {
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
            .disabled(viewModel?.conversations.isEmpty ?? true)
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
            databaseType: connection.type,
            userDefinedTypeScope: ctx.userDefinedTypeScope
        )
    }

    private var jsonView: some View {
        JSONRowInspectorView(
            viewModel: state.jsonViewModel,
            snapshot: state.inspectorContext.jsonRow,
            onOpenReferencedTable: { reference, value in
                commandActions?.openForeignKeyTable(reference: reference, value: value)
            }
        )
    }

    /// Choosing this tab is what starts the session, and it starts it from `.task` rather than from
    /// the body: creating one while SwiftUI is evaluating a view mutates the registry's observed
    /// array mid-update, and every connection window would mint a session it never used.
    ///
    /// The empty arm lasts one layout pass. The registry write invalidates this body, so a spinner
    /// would only flash.
    @ViewBuilder
    private var aiChatView: some View {
        let ctx = state.inspectorContext
        Group {
            if let viewModel = state.session?.viewModel {
                AIChatPanelView(
                    connection: connection,
                    currentQuery: ctx.currentQuery,
                    queryResults: ctx.queryResults,
                    viewModel: viewModel
                )
            } else {
                Color.clear
            }
        }
        .task(id: connection.id) {
            state.startSession()
        }
    }
}
