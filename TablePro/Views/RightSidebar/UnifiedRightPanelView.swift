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
    let connection: DatabaseConnection

    private var ctx: InspectorContext { state.inspectorContext }

    private var detailsView: some View {
        RightSidebarView(
            tableName: ctx.tableName,
            tableMetadata: ctx.tableMetadata,
            selectedRowData: ctx.selectedRowData,
            isEditable: ctx.isEditable,
            isRowDeleted: ctx.isRowDeleted,
            editState: state.editState,
            databaseType: connection.type
        )
    }

    var body: some View {
        Group {
            if AppSettingsManager.shared.ai.enabled {
                switch state.activeTab {
                case .details:
                    detailsView
                case .aiChat:
                    AIChatPanelView(
                        connection: connection,
                        currentQuery: ctx.currentQuery,
                        queryResults: ctx.queryResults,
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
