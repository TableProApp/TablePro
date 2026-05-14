//
//  ConnectionSplitContainerView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ConnectionSplitContainerView: View {
    @Bindable var tabManager: QueryTabManager
    let coordinator: MainContentCoordinator
    let connection: DatabaseConnection
    let rightPanelState: RightPanelState

    var body: some View {
        VStack(spacing: 0) {
            EditorTabStripView(
                tabManager: tabManager,
                onNewTab: { tabManager.addTab() },
                onCloseTab: { tabManager.removeTab(id: $0) },
                onSelectTab: { tabManager.selectTab(id: $0) },
                onMoveTab: { tabManager.moveTab(from: $0, to: $1) }
            )
            Divider()
            EditorTabContainerRepresentable(
                tabManager: tabManager,
                coordinator: coordinator,
                connection: connection,
                rightPanelState: rightPanelState
            )
        }
    }
}

private struct EditorTabContainerRepresentable: NSViewControllerRepresentable {
    @Bindable var tabManager: QueryTabManager
    let coordinator: MainContentCoordinator
    let connection: DatabaseConnection
    let rightPanelState: RightPanelState

    func makeNSViewController(context: Context) -> EditorTabContainerViewController {
        EditorTabContainerViewController(
            coordinator: coordinator,
            connection: connection,
            rightPanelState: rightPanelState,
            tabManager: tabManager
        )
    }

    func updateNSViewController(_ controller: EditorTabContainerViewController, context: Context) {
        controller.syncToTabManager()
    }
}
