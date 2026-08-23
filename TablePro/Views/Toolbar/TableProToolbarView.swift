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
    var connectionId: UUID?
    weak var coordinator: MainContentCoordinator?
    var onCancelQuery: (() -> Void)?
    var onSafeModeChange: ((SafeModeLevel) -> Void)?

    @State private var showingAllTags = false
    @State private var schemaService = SchemaService.shared

    /// The sidebar's own reload, reported where every other piece of background activity is. It
    /// used to sit at the bottom of the sidebar, which the HIG reserves for nothing critical
    /// because a window can be moved so that edge is off screen.
    private var isRefreshingSchema: Bool {
        guard let connectionId else { return false }
        return schemaService.isRefreshing(connectionId: connectionId)
    }

    var body: some View {
        let tags = TagStorage.shared.tags(for: state.tagIds)

        HStack(spacing: 10) {
            tagCluster(tags)

            ConnectionStatusView(
                databaseType: state.databaseType,
                databaseVersion: state.databaseVersion,
                scopeComponents: state.scopeComponents,
                connectionName: state.connectionName,
                displayColor: state.displayColor,
                safeModeLevel: state.safeModeLevel,
                coordinator: coordinator
            )

            SafeModeBadgeView(safeModeLevel: Binding(
                get: { state.safeModeLevel },
                set: { onSafeModeChange?($0) }
            ))

            ExecutionIndicatorView(
                isExecuting: coordinator?.tabExecution.isAnyExecuting ?? false,
                lastDuration: state.lastQueryDuration,
                clickHouseProgress: state.clickHouseProgress,
                lastClickHouseProgress: state.lastClickHouseProgress,
                onCancel: onCancelQuery
            )

            DelayedProgressIndicator(isActive: isRefreshingSchema)
                .accessibilityLabel(String(localized: "Refreshing"))
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

    /// A tag with no colour fills with `clear`, and a label derived from a transparent fill comes
    /// back white and disappears, so an uncoloured tag takes the standard control fill instead of
    /// a derived one.
    private func tagBadge(_ tag: ConnectionTag) -> some View {
        Text(tag.name.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(tag.color.isDefault ? .primary : Color.legibleForeground(on: tag.color.color))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                tag.color.isDefault ? Color(nsColor: .quaternarySystemFill) : tag.color.color,
                in: Capsule()
            )
    }
}
