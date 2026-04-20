//
//  MainContentView+Modifiers.swift
//  TablePro
//
//  View modifiers and preview for MainContentView.
//  Extracted to reduce main view complexity.
//

import SwiftUI

// MARK: - Toolbar Tint Modifier

/// Applies a subtle color tint to the window toolbar when a connection color is set.
struct ToolbarTintModifier: ViewModifier {
    let connectionColor: ConnectionColor

    @ViewBuilder
    func body(content: Content) -> some View {
        if connectionColor.isDefault {
            content
        } else {
            content
                .toolbarBackground(connectionColor.color.opacity(0.12), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
    }
}

// MARK: - Focused Command Actions Modifier

/// Conditionally publishes `MainContentCommandActions` as a focused scene value.
/// `focusedSceneValue` requires a non-optional value, so this modifier
/// only applies it when the actions object has been created.
struct FocusedCommandActionsModifier: ViewModifier {
    let actions: MainContentCommandActions?

    func body(content: Content) -> some View {
        if let actions {
            content.focusedSceneValue(\.commandActions, actions)
        } else {
            content
        }
    }
}

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
        tables: .constant([]),
        sidebarState: SharedSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        rightPanelState: RightPanelState(),
        tabManager: state.tabManager,
        changeManager: state.changeManager,
        filterStateManager: state.filterStateManager,
        toolbarState: state.toolbarState,
        coordinator: state.coordinator
    )
    .frame(width: 1_000, height: 600)
}
