//
//  UnifiedRightPanelView.swift
//  TablePro
//
//  Unified right panel combining Details and AI Chat into a single
//  segmented panel, reducing clutter and preserving AI conversation state.
//

import SwiftUI

struct UnifiedRightPanelView: View {
    @Bindable var state: RightPanelState
    let inspectorContext: InspectorContext
    let connection: DatabaseConnection
    let tables: [TableInfo]

    private var detailsView: some View {
        RightSidebarView(
            tableName: inspectorContext.tableName,
            tableMetadata: inspectorContext.tableMetadata,
            selectedRowData: inspectorContext.selectedRowData,
            isEditable: inspectorContext.isEditable,
            isRowDeleted: inspectorContext.isRowDeleted,
            onSave: { state.onSave?() },
            editState: state.editState,
            databaseType: connection.type
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if AppSettingsManager.shared.ai.enabled {
                Picker("", selection: $state.activeTab) {
                    ForEach(RightPanelTab.allCases, id: \.self) { tab in
                        Label(tab.localizedTitle, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                switch state.activeTab {
                case .details:
                    detailsView
                case .aiChat:
                    AIChatPanelView(
                        connection: connection,
                        tables: tables,
                        currentQuery: inspectorContext.currentQuery,
                        queryResults: inspectorContext.queryResults,
                        viewModel: state.aiViewModel
                    )
                }
            } else {
                detailsView
            }
        }
        .onChange(of: AppSettingsManager.shared.ai.enabled) {
            if !AppSettingsManager.shared.ai.enabled {
                state.activeTab = .details
            }
        }
    }
}
