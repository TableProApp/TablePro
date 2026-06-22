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

private enum ToolbarPrincipalLayout {
    static let edgePadding: CGFloat = 8
}

/// Content for the principal (center) toolbar area.
/// Displays environment badge, connection status, safe-mode badge, and execution indicator.
struct ToolbarPrincipalContent: View {
    var state: ConnectionToolbarState
    var onSwitchDatabase: (() -> Void)?
    var onCancelQuery: (() -> Void)?
    var onSafeModeChange: ((SafeModeLevel) -> Void)?

    @State private var showingAllTags = false

    var body: some View {
        let tags = TagStorage.shared.tags(for: state.tagIds)

        HStack(spacing: 10) {
            tagCluster(tags)

            ConnectionStatusView(
                databaseType: state.databaseType,
                databaseVersion: state.databaseVersion,
                chipText: state.chipText,
                databaseGroupingStrategy: state.databaseGroupingStrategy,
                connectionName: state.connectionName,
                displayColor: state.displayColor,
                safeModeLevel: state.safeModeLevel,
                onSwitchDatabase: onSwitchDatabase
            )

            SafeModeBadgeView(safeModeLevel: Binding(
                get: { state.safeModeLevel },
                set: { onSafeModeChange?($0) }
            ))

            ExecutionIndicatorView(
                isExecuting: state.isExecuting,
                lastDuration: state.lastQueryDuration,
                clickHouseProgress: state.clickHouseProgress,
                lastClickHouseProgress: state.lastClickHouseProgress,
                onCancel: onCancelQuery
            )
        }
        .padding(.horizontal, ToolbarPrincipalLayout.edgePadding)
    }

    @ViewBuilder
    private func tagCluster(_ tags: [ConnectionTag]) -> some View {
        if let first = tags.first {
            let names = tags.map(\.name).joined(separator: ", ")
            let overflow = tags.count - 1

            Button {
                showingAllTags = true
            } label: {
                HStack(spacing: 4) {
                    tagBadge(first)
                    if overflow > 0 {
                        Text(verbatim: "+\(overflow)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(names)
            .accessibilityLabel(String(format: String(localized: "Tags: %@"), names))
            .popover(isPresented: $showingAllTags, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tags) { tag in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tag.color.color)
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func tagBadge(_ tag: ConnectionTag) -> some View {
        Text(tag.name.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tag.color.color, in: Capsule())
    }
}
