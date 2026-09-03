//
//  ConnectionSwitcherPopover.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProPluginKit

enum ConnectionSwitcherFilter {
    static func matches(_ connection: DatabaseConnection, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return FuzzyMatcher.matches(query: trimmed, candidate: connection.name)
            || FuzzyMatcher.matches(query: trimmed, candidate: connection.host)
            || FuzzyMatcher.matches(query: trimmed, candidate: connection.database)
    }
}

enum ConnectionSwitcherSelection {
    static func moved(in ids: [UUID], from current: UUID?, by offset: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        let currentIndex = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        let newIndex = max(0, min(ids.count - 1, currentIndex + offset))
        return ids[newIndex]
    }
}

/// The two sections list different things, a live session and a saved record, but the list shows one
/// kind of row, so they are resolved into one before they reach it.
struct ConnectionSwitcherEntry: Identifiable {
    let id: UUID
    let connection: DatabaseConnection
    let isActive: Bool
    let isConnected: Bool
}

struct ConnectionSwitcherPopover: View {
    /// An explicit closure rather than `@Environment(\.dismiss)`, because the presenter owns the
    /// surface: `dismiss` reaches a SwiftUI presentation, and this content is hosted in an AppKit
    /// popover or panel that SwiftUI knows nothing about. `PopoverPresenter` hands every caller the
    /// same shape.
    let dismiss: () -> Void

    @State private var savedConnections: [DatabaseConnection] = []
    @State private var groups: [ConnectionGroup] = []
    @State private var hostedWithoutSession: [DatabaseConnection] = []
    @State private var selectedConnectionId: UUID?
    @State private var searchText = ""

    /// One declaration, read by this view's own frame and by whoever presents it, so the
    /// surface and its host can never disagree about how big it is.
    static let contentSize = NSSize(width: 400, height: 460)

    private var activeSessions: [UUID: ConnectionSession] {
        DatabaseManager.shared.activeSessions
    }

    private var currentSessionId: UUID? {
        DatabaseManager.shared.lastActiveSessionId
    }

    private var sortedSessions: [ConnectionSession] {
        Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Open means a window hosts it, which is not the same as a session existing for it. A
    /// workspace outlives its session, so a connect that failed, one the user cancelled and an
    /// explicit disconnect all leave a connection open with nothing in `activeSessions`. Listing
    /// those under a group would put a connection the window is already showing in the library
    /// half, where Command-click promises a window it will not get.
    ///
    /// Held in state rather than read during `body`, because `WindowManager` is not observable and
    /// nothing would re-evaluate this when a window opens or closes.
    private var openEntries: [ConnectionSwitcherEntry] {
        var entries = sortedSessions.map {
            ConnectionSwitcherEntry(
                id: $0.id,
                connection: $0.connection,
                isActive: $0.id == currentSessionId,
                isConnected: $0.status.isConnected
            )
        }
        entries += hostedWithoutSession.map {
            ConnectionSwitcherEntry(id: $0.id, connection: $0, isActive: false, isConnected: false)
        }
        return entries
    }

    private var openConnectionIds: Set<UUID> {
        Set(activeSessions.keys).union(hostedWithoutSession.map(\.id))
    }

    private var inactiveSaved: [DatabaseConnection] {
        let open = openConnectionIds
        return savedConnections.filter { !open.contains($0.id) }
    }

    private var filteredOpen: [ConnectionSwitcherEntry] {
        openEntries.filter { ConnectionSwitcherFilter.matches($0.connection, query: searchText) }
    }

    private var filteredSaved: [DatabaseConnection] {
        inactiveSaved.filter { ConnectionSwitcherFilter.matches($0, query: searchText) }
    }

    /// Read off the sections rather than assembled a second time, so the order the arrow keys walk
    /// is the order the list draws by construction.
    private var orderedIds: [UUID] {
        sections.flatMap { $0.items.map(\.id) }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content

            Divider()

            manageButton
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .onAppear {
            reload()
            if selectedConnectionId == nil {
                selectedConnectionId = currentSessionId ?? orderedIds.first
            }
        }
        /// The subject itself, not a `receive(on:)` wrapper: that builds a new publisher on every
        /// body pass, and every sender is already on the main actor.
        .onReceive(AppEvents.shared.connectionUpdated) { _ in
            reload()
            settleSelection()
        }
        .onReceive(AppEvents.shared.connectionWindowsChanged) { _ in
            reload()
            settleSelection()
        }
        .onChange(of: searchText) { _, _ in
            settleSelection()
        }
    }

    private var searchField: some View {
        NativeSearchField(
            text: $searchText,
            placeholder: String(localized: "Search connections"),
            onMoveUp: { moveSelection(by: -1) },
            onMoveDown: { moveSelection(by: 1) },
            onSubmit: { activateSelected() },
            focusOnAppear: true
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if orderedIds.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var sections: [FieldDrivenListSection<ConnectionSwitcherEntry>] {
        ConnectionSwitcherSections.build(
            active: filteredOpen,
            saved: filteredSaved,
            groups: groups,
            isFiltering: isFiltering
        )
    }

    /// The search field keeps focus for the whole flow, so the list is a presentation of that
    /// field's selection rather than a second focusable control. See `FieldDrivenList`.
    private var list: some View {
        FieldDrivenList(
            sections: sections,
            selection: Binding(
                get: { selectedConnectionId.map { [$0] } ?? [] },
                set: { selectedConnectionId = $0.first }
            ),
            rowHeight: 40,
            usesSourceListStyle: true,
            onSingleClickAction: { activate(connectionId: $0) },
            onPrimaryAction: { activate(connectionId: $0) },
            row: { entry in
                connectionRow(
                    connection: entry.connection,
                    isActive: entry.isActive,
                    isConnected: entry.isConnected
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text(String(localized: "No connections"))
                    .font(.callout.weight(.medium))
            } else {
                Text(String(format: String(localized: "No connections match “%@”"), searchText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var manageButton: some View {
        Button {
            dismiss()
            WindowOpener.shared.openWelcome()
        } label: {
            HStack {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
                Text("Manage Connections…")
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func connectionRow(
        connection: DatabaseConnection,
        isActive: Bool,
        isConnected: Bool
    ) -> some View {
        let metadata = ConnectionMetadata.resolve(
            connection: connection,
            tags: TagStorage.shared.loadTags(),
            groups: GroupStorage.shared.loadGroups()
        )
        return HStack(spacing: 8) {
            Circle()
                .selectionAwareTint(connection.identityColor?.indicatorColor ?? .secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(connectionSubtitle(connection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let group = metadata.group {
                        ConnectionGroupBadge(group: group)
                            .layoutPriority(1)
                    }
                }
            }

            Spacer()

            ConnectionTagsBadge(tags: metadata.tags)

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .selectionAwareTint(.green)
                    .font(.body)
            } else if isConnected {
                Circle()
                    .selectionAwareTint(.green)
                    .frame(width: 6, height: 6)
            }

            Text(connection.type.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color(nsColor: .separatorColor), in: RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Selection

    private func reload() {
        let saved = ConnectionStorage.shared.loadConnections()
        savedConnections = saved
        groups = GroupStorage.shared.loadGroups()

        hostedWithoutSession = ConnectionSwitcherSections.hostedWithoutSession(
            workspaces: WindowManager.shared.hostedWorkspaces().map { ($0.connectionId, $0.connection) },
            sessionIds: Set(DatabaseManager.shared.activeSessions.keys),
            saved: saved
        )
    }

    private func settleSelection() {
        let ids = orderedIds
        if let id = selectedConnectionId, ids.contains(id) { return }
        selectedConnectionId = ids.first
    }

    private func moveSelection(by offset: Int) {
        if let next = ConnectionSwitcherSelection.moved(in: orderedIds, from: selectedConnectionId, by: offset) {
            selectedConnectionId = next
        }
    }

    private func activateSelected() {
        guard let id = selectedConnectionId else { return }
        activate(connectionId: id)
    }

    /// Command-click opens a saved connection in a window of its own, the modifier Finder and
    /// Safari use for the same intent. A connection already open is switched to either way: moving
    /// one between windows belongs to the connections strip, which owns that arrangement.
    ///
    /// Whether a window already hosts it is settled by the router, next to the window it builds,
    /// rather than here where the answer would be a main-actor job old by the time it is used.
    private func activate(connectionId: UUID) {
        let opensNewWindow = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        dismiss()
        Task {
            do {
                if opensNewWindow {
                    try await TabRouter.shared.openConnectionPreferringNewWindow(id: connectionId)
                } else {
                    try await TabRouter.shared.route(.openConnection(connectionId))
                }
            } catch {
                await MainActor.run {
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Connection Failed"),
                        message: error.localizedDescription,
                        window: NSApp.keyWindow
                    )
                }
            }
        }
    }

    private func connectionSubtitle(_ connection: DatabaseConnection) -> String {
        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased {
            return connection.database
        }
        let port = connection.port != connection.type.defaultPort ? ":\(connection.port)" : ""
        return "\(connection.host)\(port)/\(connection.database)"
    }
}

// MARK: - Sections

internal enum ConnectionSwitcherSections {
    /// Open connections keep their own section at the top: they are the working set, and burying
    /// one inside its group would put the two connections a user switches between furthest apart.
    /// Everything below is the library, and that is where the group hierarchy belongs.
    ///
    /// A filter collapses the groups back into one list. A search is a lookup rather than a browse,
    /// and a connection matching in each of eight groups would otherwise be eight one-row sections.
    internal static func build(
        active: [ConnectionSwitcherEntry],
        saved: [DatabaseConnection],
        groups: [ConnectionGroup],
        isFiltering: Bool
    ) -> [FieldDrivenListSection<ConnectionSwitcherEntry>] {
        var sections = [
            FieldDrivenListSection(
                id: "active",
                title: String(localized: "ACTIVE CONNECTIONS"),
                items: active
            ),
        ]

        guard !isFiltering else {
            sections.append(
                FieldDrivenListSection(
                    id: "saved",
                    title: String(localized: "SAVED CONNECTIONS"),
                    items: saved.map(entry)
                )
            )
            return sections
        }

        var ungrouped: [DatabaseConnection] = []
        let sectionsBeforeGroups = sections.count
        append(
            buildGroupTreeIndexed(groups: groups, connections: saved),
            path: [],
            into: &sections,
            ungrouped: &ungrouped
        )

        guard !ungrouped.isEmpty else { return sections }

        /// "Ungrouped" only means anything beside a group. With no groups on screen there is
        /// nothing for it to contrast with, and the list is just the saved connections.
        let hasGroups = sections.count > sectionsBeforeGroups
        sections.append(
            FieldDrivenListSection(
                id: "ungrouped",
                title: hasGroups ? String(localized: "UNGROUPED") : String(localized: "SAVED CONNECTIONS"),
                items: ungrouped.map(entry)
            )
        )
        return sections
    }

    /// The connections a window still holds with no session behind them, deduplicated and named.
    ///
    /// One connection can be hosted twice once it has been moved into a window of its own, and a
    /// workspace that never got as far as a session has no record of its own, so the saved list
    /// answers for it.
    internal static func hostedWithoutSession(
        workspaces: [(connectionId: UUID, connection: DatabaseConnection?)],
        sessionIds: Set<UUID>,
        saved: [DatabaseConnection]
    ) -> [DatabaseConnection] {
        var seen: Set<UUID> = []
        return workspaces.compactMap { workspace in
            guard !sessionIds.contains(workspace.connectionId),
                  seen.insert(workspace.connectionId).inserted else { return nil }
            return workspace.connection ?? saved.first { $0.id == workspace.connectionId }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func entry(for connection: DatabaseConnection) -> ConnectionSwitcherEntry {
        ConnectionSwitcherEntry(id: connection.id, connection: connection, isActive: false, isConnected: false)
    }

    /// One section per group, in the order the connection list shows them, with a nested group
    /// naming its whole path. The header carries the group's own colour, and the connections that
    /// belong to no group come last, which is where the tree puts them too.
    private static func append(
        _ nodes: [ConnectionGroupTreeNode],
        path: [String],
        into sections: inout [FieldDrivenListSection<ConnectionSwitcherEntry>],
        ungrouped: inout [DatabaseConnection]
    ) {
        for node in nodes {
            switch node {
            case .connection(let connection):
                ungrouped.append(connection)
            case .group(let group, let children):
                var connections: [DatabaseConnection] = []
                var subgroups: [ConnectionGroupTreeNode] = []
                for child in children {
                    if case .connection(let connection) = child {
                        connections.append(connection)
                    } else {
                        subgroups.append(child)
                    }
                }

                /// A group with nothing under it draws no header, so it contributes no section
                /// either. Leaving an empty one in made the list claim a hierarchy it was not
                /// showing, and the loose connections then read as "ungrouped" against nothing.
                /// A parent whose own connections are elsewhere still names itself through its
                /// children's path.
                let names = path + [group.name]
                if !connections.isEmpty {
                    sections.append(
                        FieldDrivenListSection(
                            id: "group-\(group.id)",
                            title: names.joined(separator: " / ").localizedUppercase,
                            accentColor: group.color.indicatorColor.map(NSColor.init),
                            items: connections.map(entry)
                        )
                    )
                }
                append(subgroups, path: names, into: &sections, ungrouped: &ungrouped)
            }
        }
    }
}
