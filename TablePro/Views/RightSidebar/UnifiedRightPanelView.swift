//
//  UnifiedRightPanelView.swift
//  TablePro
//

import SwiftUI

struct UnifiedRightPanelView: View {
    @Bindable var state: RightPanelState
    let connection: DatabaseConnection

    private let settingsManager = AppSettingsManager.shared

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
    }

    private var splitContent: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            switch state.activeTab {
            case .details: detailsView
            case .aiChat:  aiChatView
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $state.activeTab) {
            ForEach(RightPanelTab.allCases, id: \.self) { tab in
                Text(tab.localizedTitle).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
