//
//  TableProToolbarView.swift
//  TablePro
//
//  Principal-area content composition for the main NSToolbar (configured in MainWindowToolbar).
//  This file used to also define a SwiftUI `.toolbar { ... }` modifier; that path was replaced
//  by NSToolbar and removed.
//

import SwiftUI
import TableProPluginKit

/// Content for the principal (center) toolbar area.
/// Displays environment badge, connection status, safe-mode badge, and execution indicator.
struct ToolbarPrincipalContent: View {
    var state: ConnectionToolbarState
    var onSwitchDatabase: (() -> Void)?
    var onCancelQuery: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let tagId = state.tagId,
               let tag = TagStorage.shared.tag(for: tagId)
            {
                TagBadgeView(tag: tag)
            }

            ConnectionStatusView(
                databaseType: state.databaseType,
                databaseVersion: state.databaseVersion,
                databaseName: state.databaseName,
                connectionName: state.connectionName,
                connectionState: state.connectionState,
                displayColor: state.displayColor,
                tagName: state.tagId.flatMap { TagStorage.shared.tag(for: $0)?.name },
                safeModeLevel: state.safeModeLevel,
                onSwitchDatabase: onSwitchDatabase
            )

            SafeModeBadgeView(safeModeLevel: Bindable(state).safeModeLevel)

            ExecutionIndicatorView(
                isExecuting: state.isExecuting,
                lastDuration: state.lastQueryDuration,
                clickHouseProgress: state.clickHouseProgress,
                lastClickHouseProgress: state.lastClickHouseProgress,
                onCancel: onCancelQuery
            )
        }
    }
}
