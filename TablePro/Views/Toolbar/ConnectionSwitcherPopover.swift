//
//  ConnectionSwitcherPopover.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProConnectionLibrary
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

    let currentConnectionId: UUID?

    @State private var savedConnections: [DatabaseConnection] = []
    @State private var groups: [ConnectionGroup] = []
    @State private var tags: [ConnectionTag] = []
    @State private var hostedWithoutSession: [DatabaseConnection] = []
    @State private var selectedConnectionId: UUID?
    @State private var searchText = ""

    /// One declaration, read by this view's own frame and by whoever presents it, so the
    /// surface and its host can never disagree about how big it is.
    static let contentSize = NSSize(width: 400, height: 460)

    private var activeSessions: [UUID: ConnectionSession] {
        DatabaseManager.shared.activeSessions
    }

    private var currentConnection: DatabaseConnection? {
        currentConnectionId.flatMap { activeSessions[$0]?.connection }
    }

    private var sortedSessions: [ConnectionSession] {
        Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Open means a window hosts it, which is not the same as a session existing for it. A
    /// workspace outlives its session, so a connect that failed, one the user cancelled and an
    /// explicit disconnect all leave a connection open with nothing in `activeSessions`.
    private var openEntries: [ConnectionSwitcherEntry] {
        var entries = sortedSessions.map {
            ConnectionSwitcherEntry(
                id: $0.id,
                connection: $0.connection,
                isActive: $0.id == currentConnectionId,
                isConnected: $0.reportedStatus.isConnected
            )
        }
        entries += hostedWithoutSession.map {
            ConnectionSwitcherEntry(id: $0.id, connection: $0, isActive: $0.id == currentConnectionId, isConnected: false)
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

            ConnectionActivityFooter(connection: currentConnection)

            Divider()

            manageButton
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .onAppear {
            reload()
            if selectedConnectionId == nil {
                selectedConnectionId = currentConnectionId.flatMap { id in orderedIds.contains(id) ? id : nil }
                    ?? orderedIds.first
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
        .onReceive(AppEvents.shared.connectionStatusChanged) { _ in
            reload()
            settleSelection()
        }
        .onReceive(AppEvents.shared.connectionListStateChanged) { _ in
            reload()
            settleSelection()
        }
        .onChange(of: searchText) { _ in
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
        let recents = RecentConnectionsStore.shared.lastConnected
        let sortMode = ConnectionListPreferences.shared.sortMode
        let saved = LibrarySorting.sorted(filteredSaved, mode: sortMode, lastConnected: recents)
        let favoriteIds = Set(saved.filter(\.isFavorite).map(\.id))
        let favoritesOrder = ConnectionListPreferences.shared.favoritesOrder
        let favorites = saved.filter(\.isFavorite).sorted { lhs, rhs in
            let left = favoritesOrder.firstIndex(of: lhs.id) ?? Int.max
            let right = favoritesOrder.firstIndex(of: rhs.id) ?? Int.max
            return left < right
        }
        let recent = saved
            .filter { !favoriteIds.contains($0.id) && recents[$0.id] != nil }
            .sorted { (recents[$0.id] ?? .distantPast) > (recents[$1.id] ?? .distantPast) }
            .prefix(LibraryOutlineBuilder.defaultRecentLimit)
        return ConnectionSwitcherSections.build(
            active: filteredOpen,
            saved: saved,
            groups: groups,
            isFiltering: isFiltering,
            favorites: sortMode == .manual ? favorites : saved.filter(\.isFavorite),
            recent: Array(recent)
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
                connectionRow(entry)
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

    private func connectionRow(_ entry: ConnectionSwitcherEntry) -> some View {
        let connection = entry.connection
        let group = connection.groupId.flatMap { id in groups.first { $0.id == id } }
        let connectionTags = connection.tagIds.compactMap { id in tags.first { $0.id == id } }
        return HStack(spacing: 8) {
            ConnectionTile(type: connection.type, identityColor: connection.identityColor, size: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.body.weight(entry.isActive ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(connection.connectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let group {
                        ConnectionSymbolLabel(
                            systemName: "folder.fill",
                            label: WelcomeTagLabel(name: group.name, color: group.color)
                        )
                    }
                    if let tag = connectionTags.first {
                        ConnectionSymbolLabel(
                            systemName: "tag.fill",
                            label: WelcomeTagLabel(name: tag.name, color: tag.color)
                        )
                    }
                }
            }

            Spacer()

            if entry.isActive {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .selectionAwareTint(.accentColor)
                    .accessibilityLabel(Text("Current connection"))
            } else if entry.isConnected {
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        tags = TagStorage.shared.loadTags()

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
}

// MARK: - Sections

internal enum ConnectionSwitcherSections {
    /// Open connections keep their own section at the top: they are the working set. Favorites and
    /// recent connections come next, then the library by group. Each connection is listed once, so
    /// a favorite is not repeated under its group here: the arrow keys walk every row, and a quick
    /// chooser with one connection in two places would stop twice on it.
    ///
    /// A filter collapses everything below the open connections back into one list. A search is a
    /// lookup rather than a browse, and a connection matching in each of eight groups would
    /// otherwise be eight one-row sections.
    internal static func build(
        active: [ConnectionSwitcherEntry],
        saved: [DatabaseConnection],
        groups: [ConnectionGroup],
        isFiltering: Bool,
        favorites: [DatabaseConnection] = [],
        recent: [DatabaseConnection] = []
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

        if !favorites.isEmpty {
            sections.append(FieldDrivenListSection(
                id: "favorites",
                title: String(localized: "FAVORITES"),
                items: favorites.map(entry)
            ))
        }
        if !recent.isEmpty {
            sections.append(FieldDrivenListSection(
                id: "recent",
                title: String(localized: "RECENT"),
                items: recent.map(entry)
            ))
        }

        let listedIds = Set(favorites.map(\.id)).union(recent.map(\.id))
        let library = saved.filter { !listedIds.contains($0.id) }
        let graph = LibraryGroupGraph(groups: groups)
        var byGroup: [UUID: [DatabaseConnection]] = [:]
        var ungrouped: [DatabaseConnection] = []
        for connection in library {
            if let groupId = connection.groupId, graph.contains(groupId) {
                byGroup[groupId, default: []].append(connection)
            } else {
                ungrouped.append(connection)
            }
        }

        let sectionsBeforeGroups = sections.count
        for flat in graph.flattened() {
            guard let connections = byGroup[flat.id], !connections.isEmpty else { continue }
            let names = graph.pathNames(to: flat.id)
            sections.append(
                FieldDrivenListSection(
                    id: "group-\(flat.id)",
                    title: names.joined(separator: " / ").localizedUppercase,
                    items: connections.map(entry)
                )
            )
        }

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
}
