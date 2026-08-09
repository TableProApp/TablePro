//
//  ConnectionsTabView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Where a connection stands relative to the window drawing the list. Shape carries
/// the state, so it reads the same to someone who cannot tell green from grey.
internal enum ConnectionRowPresence: Equatable {
    case current
    case openElsewhere
    case closed

    internal static func resolve(
        connectionId: UUID,
        windowConnectionId: UUID,
        openConnectionIds: Set<UUID>
    ) -> ConnectionRowPresence {
        if connectionId == windowConnectionId { return .current }
        return openConnectionIds.contains(connectionId) ? .openElsewhere : .closed
    }
}

/// Every saved connection, grouped the way the welcome window groups them, so another
/// connection is reachable without leaving the window you are working in.
///
/// Opening one raises that connection's own window or makes it a new one. Nothing here
/// retargets the window you are in: its tabs stay bound to the connection they were
/// opened against.
internal struct ConnectionsTabView: View {
    internal let connectionId: UUID
    @Bindable private var sharedSidebarState: SharedSidebarState

    @State private var connections: [DatabaseConnection] = []
    @State private var groups: [ConnectionGroup] = []
    @State private var openConnectionIds: Set<UUID> = []

    internal init(connectionId: UUID, sharedSidebarState: SharedSidebarState) {
        self.connectionId = connectionId
        self.sharedSidebarState = sharedSidebarState
    }

    private var searchText: String { sharedSidebarState.connectionsSearchText }

    private var tree: [ConnectionGroupTreeNode] {
        let built = buildGroupTreeIndexed(groups: groups, connections: connections)
        return filterGroupTree(built, searchText: searchText)
    }

    /// A window opened from a URL runs a connection that was never saved, so counting
    /// the saved list is not the same as asking whether anywhere else is reachable.
    private var hasSomewhereElseToGo: Bool {
        connections.contains { $0.id != connectionId }
    }

    internal var body: some View {
        content
            .onAppear(perform: reload)
            .onReceive(AppEvents.shared.connectionUpdated) { _ in reload() }
            .onReceive(AppEvents.shared.connectionWindowsChanged) { _ in
                openConnectionIds = WorkspaceRailStore.openConnectionIds
            }
    }

    @ViewBuilder
    private var content: some View {
        if !hasSomewhereElseToGo {
            noOtherConnections
        } else if tree.isEmpty {
            noMatches
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $sharedSidebarState.selectedConnectionsItem) {
            ConnectionTreeRows(
                nodes: tree,
                windowConnectionId: connectionId,
                openConnectionIds: openConnectionIds
            )
        }
        .sidebarListLayout()
        .contextMenu(forSelectionType: String.self) { selection in
            menu(for: selection.first)
        } primaryAction: { selection in
            open(selection.first)
        }
    }

    @ViewBuilder
    private func menu(for id: String?) -> some View {
        if let id, let node = findGroupTreeNode(id: id, in: tree) {
            switch node {
            case .connection(let connection):
                Button(String(localized: "Open")) {
                    open(id)
                }
                .disabled(connection.id == connectionId)
                Button(String(localized: "Edit Connection...")) {
                    WindowOpener.shared.openConnectionForm(editing: connection.id)
                }
            case .group(let group, _):
                Button(String(localized: "Expand All")) {
                    ConnectionGroupExpansionState.shared.expand(subtree(of: group))
                }
                Button(String(localized: "Collapse All")) {
                    ConnectionGroupExpansionState.shared.collapse(subtree(of: group))
                }
            }
            Divider()
        }
        SidebarViewOptionsMenu()
    }

    private var noOtherConnections: some View {
        ContentUnavailableView {
            Label(String(localized: "No Other Connections"), systemImage: "cylinder.split.1x2")
        } description: {
            Text("Connections you save appear here, grouped the way you arrange them.")
        } actions: {
            Button(String(localized: "New Connection...")) {
                WindowOpener.shared.openConnectionForm()
            }
        }
    }

    private var noMatches: some View {
        ContentUnavailableView.search(text: searchText)
    }

    private func subtree(of group: ConnectionGroup) -> Set<UUID> {
        collectAllDescendantGroupIds(groupId: group.id, groups: groups).union([group.id])
    }

    private func open(_ id: String?) {
        guard let id, let node = findGroupTreeNode(id: id, in: tree) else { return }
        guard case .connection(let connection) = node else { return }
        guard connection.id != connectionId else { return }
        Task { await ConnectionActivation.open(connectionId: connection.id) }
    }

    private func reload() {
        connections = ConnectionStorage.shared.loadConnections()
        groups = GroupStorage.shared.loadGroups()
        openConnectionIds = WorkspaceRailStore.openConnectionIds
        ConnectionGroupExpansionState.shared.expandAllIfNeeded(groups: groups)
    }
}

/// Recursive because a group can hold groups, up to the three levels `GroupStorage`
/// allows. Expansion never follows the filter: filtering removes rows, the way the
/// favorites tree and the welcome window both already behave.
private struct ConnectionTreeRows: View {
    let nodes: [ConnectionGroupTreeNode]
    let windowConnectionId: UUID
    let openConnectionIds: Set<UUID>

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .connection(let connection):
                ConnectionSidebarRow(
                    connection: connection,
                    presence: ConnectionRowPresence.resolve(
                        connectionId: connection.id,
                        windowConnectionId: windowConnectionId,
                        openConnectionIds: openConnectionIds
                    )
                )
                .tag(node.id)
            case .group(let group, let children):
                DisclosureGroup(isExpanded: expansion(for: group)) {
                    ConnectionTreeRows(
                        nodes: children,
                        windowConnectionId: windowConnectionId,
                        openConnectionIds: openConnectionIds
                    )
                } label: {
                    ConnectionGroupSidebarRow(group: group)
                }
                .tag(node.id)
            }
        }
    }

    private func expansion(for group: ConnectionGroup) -> Binding<Bool> {
        Binding(
            get: { ConnectionGroupExpansionState.shared.isExpanded(group.id) },
            set: { ConnectionGroupExpansionState.shared.setExpanded(group.id, expanded: $0) }
        )
    }
}

private struct ConnectionGroupSidebarRow: View {
    let group: ConnectionGroup

    var body: some View {
        Label {
            Text(group.name)
        } icon: {
            Image(systemName: "folder")
                .sidebarTint(group.color.isDefault ? .secondary : group.color.color)
        }
        .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
    }
}

private struct ConnectionSidebarRow: View {
    let connection: DatabaseConnection
    let presence: ConnectionRowPresence

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text(connection.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                connection.type.iconImage
                    .sidebarTint(connection.displayColor)
            }
            .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)

            Spacer(minLength: 0)

            presenceAccessory
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var presenceAccessory: some View {
        switch presence {
        case .current:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .openElsewhere:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.green)
        case .closed:
            EmptyView()
        }
    }

    private var tooltip: String {
        let detail = PluginManager.shared.connectionMode(for: connection.type) == .fileBased
            ? connection.database
            : "\(connection.host)/\(connection.database)"
        return "\(connection.name)\n\(detail)"
    }

    private var accessibilityLabel: String {
        switch presence {
        case .current:
            return String(format: String(localized: "%@, current connection"), connection.name)
        case .openElsewhere:
            return String(format: String(localized: "%@, open in another window"), connection.name)
        case .closed:
            return connection.name
        }
    }
}
