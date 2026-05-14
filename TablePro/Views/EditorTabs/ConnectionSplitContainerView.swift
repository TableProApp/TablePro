//
//  ConnectionSplitContainerView.swift
//  TablePro
//
//  Detail-pane content for a connection window: the in-window tab strip on
//  top, the existing MainContentView (selected-tab content) filling the rest.
//

import SwiftUI

struct ConnectionSplitContainerView: View {
    let connection: DatabaseConnection
    @Binding var windowTitle: String
    var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    @Binding var tableOperationOptions: [String: TableOperationOptions]
    var rightPanelState: RightPanelState
    @Bindable var tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator

    var body: some View {
        VStack(spacing: 0) {
            EditorTabStripView(
                tabManager: tabManager,
                onNewTab: { coordinator.addNewQueryTab() },
                onCloseTab: { tabId in
                    tabManager.selectTab(id: tabId)
                    coordinator.commandActions?.closeTab()
                },
                onSelectTab: { tabManager.selectTab(id: $0) },
                onMoveTab: { tabManager.moveTab(from: $0, to: $1) }
            )
            Divider()
            MainContentView(
                connection: connection,
                payload: nil,
                windowTitle: $windowTitle,
                sidebarState: sidebarState,
                pendingTruncates: $pendingTruncates,
                pendingDeletes: $pendingDeletes,
                tableOperationOptions: $tableOperationOptions,
                rightPanelState: rightPanelState,
                tabManager: tabManager,
                changeManager: changeManager,
                toolbarState: toolbarState,
                coordinator: coordinator
            )
        }
    }
}
