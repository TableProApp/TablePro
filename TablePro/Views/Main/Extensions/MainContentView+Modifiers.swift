//
//  MainContentView+Modifiers.swift
//  TablePro
//
//  View modifiers and preview for MainContentView.
//  Extracted to reduce main view complexity.
//

import SwiftUI

// MARK: - Preview

#Preview("With Connection") {
    let state = SessionStateFactory.create(
        connection: DatabaseConnection.preview,
        payload: nil
    )
    MainContentView(
        connection: DatabaseConnection.preview,
        payload: nil,
        windowTitle: .constant("SQL Query"),
        windowSubtitle: .constant(""),
        sidebarState: SharedSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        rightPanelState: RightPanelState(),
        tabManager: state.tabManager,
        changeManager: state.changeManager,
        toolbarState: state.toolbarState,
        coordinator: state.coordinator
    )
    .frame(width: 1_000, height: 600)
}
