import SwiftUI
import TableProConnectionLibrary
import TableProImport
import TableProModels
import TableProSyncTransport
import UniformTypeIdentifiers

nonisolated struct ConnectionTagToken: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
}

private enum ConnectionListSheet: Identifiable {
    case addConnection
    case editConnection(DatabaseConnection)
    case moveConnections([UUID])
    case newGroup(parentId: UUID?)
    case editGroup(ConnectionGroup)
    case groups
    case tags
    case settings
    case importFile(URL)
    case export

    var id: String {
        switch self {
        case .addConnection: "addConnection"
        case .editConnection(let connection): "editConnection-\(connection.id.uuidString)"
        case .moveConnections(let ids): "moveConnections-\(ids.map(\.uuidString).joined(separator: ","))"
        case .newGroup(let parentId): "newGroup-\(parentId?.uuidString ?? "root")"
        case .editGroup(let group): "editGroup-\(group.id.uuidString)"
        case .groups: "groups"
        case .tags: "tags"
        case .settings: "settings"
        case .importFile(let url): "importFile-\(url.absoluteString)"
        case .export: "export"
        }
    }
}

struct ConnectionListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ConnectionCoordinatorStore.self) private var coordinatorStore
    @SceneStorage("lastConnectionId") private var selectedConnectionIdString: String?
    @AppStorage(AppPreferences.cloudSyncEnabledKey) private var cloudSyncEnabled = true

    @State private var searchText = ""
    @State private var searchTokens: [ConnectionTagToken] = []
    @State private var matchesAllTags = false
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<LibraryRowID> = []
    @State private var renamingConnectionId: UUID?
    @State private var activeSheet: ConnectionListSheet?
    @State private var connectionsPendingDeletion: Set<UUID> = []
    @State private var groupPendingDeletion: ConnectionGroup?
    @State private var showingFileImporter = false
    @State private var importResultCount: Int?

    private var selectedConnectionUUID: UUID? {
        selectedConnectionIdString.flatMap { UUID(uuidString: $0) }
    }

    private var openConnection: Binding<DatabaseConnection?> {
        Binding(
            get: {
                guard let id = selectedConnectionUUID else { return nil }
                return appState.connections.first { $0.id == id }
            },
            set: { selectedConnectionIdString = $0?.id.uuidString }
        )
    }

    private var isSyncing: Bool {
        appState.syncCoordinator.status == .syncing
    }

    private var isEditing: Bool {
        editMode == .active
    }

    private var query: LibraryQuery {
        LibraryQuery(
            text: searchText,
            tagIds: Set(searchTokens.map(\.id)),
            tagMatch: matchesAllTags ? .all : .any
        )
    }

    private var outline: LibraryOutline {
        LibraryOutlineBuilder.build(LibraryOutlineRequest(
            connections: appState.connections,
            groups: appState.groups,
            tags: appState.tags,
            sortMode: appState.libraryPreferences.sortMode,
            query: query,
            favoritesOrder: appState.libraryPreferences.favoritesOrder,
            lastConnected: appState.libraryPreferences.lastConnected
        ))
    }

    private var suggestedTokens: [ConnectionTagToken] {
        let chosen = Set(searchTokens.map(\.id))
        let text = searchText.trimmingCharacters(in: .whitespaces)
        return appState.tags
            .filter { !chosen.contains($0.id) }
            .filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
            .map { ConnectionTagToken(id: $0.id, name: $0.name) }
    }

    private var selectedConnectionIds: [UUID] {
        var seen: Set<UUID> = []
        return selection.compactMap { row -> UUID? in
            guard case .connection(let id, _) = row, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connections")
                .toolbar { toolbarContent }
                .onChange(of: appState.pendingConnectionId) { _, newId in
                    navigateToPendingConnection(newId)
                }
                .onChange(of: editMode) { _, mode in
                    guard mode == .inactive else { return }
                    selection = []
                }
                .onChange(of: appState.tags) { _, tags in
                    let known = Set(tags.map(\.id))
                    searchTokens.removeAll { !known.contains($0.id) }
                }
                .onAppear {
                    navigateToPendingConnection(appState.pendingConnectionId)
                    presentPendingImport()
                }
        }
        .fullScreenCover(item: openConnection) { connection in
            ConnectedView(connection: connection)
                .id(connection.id)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.tableproConnectionShare],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            activeSheet = .importFile(url)
        }
        .onChange(of: appState.pendingImportURL) { _, _ in
            presentPendingImport()
        }
        .alert(importResultMessage, isPresented: importResultPresented) {
            Button(String(localized: "OK")) { importResultCount = nil }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.connections.isEmpty && !isSyncing {
            ContentUnavailableView {
                Label("No Connections", systemImage: "server.rack")
            } description: {
                Text("Add a database connection to get started.")
            } actions: {
                Button("Add Connection") {
                    activeSheet = .addConnection
                }
                .buttonStyle(.borderedProminent)
            }
        } else if appState.connections.isEmpty {
            ProgressView("Syncing from iCloud...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            libraryList
        }
    }

    private var libraryList: some View {
        let outline = outline
        let connectionsById = Dictionary(appState.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupsById = Dictionary(appState.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let canReorder = appState.libraryPreferences.sortMode == .manual && !outline.isQueryActive

        return List(selection: $selection) {
            ForEach(outline.sections, id: \.kind) { section in
                Section {
                    switch section.kind {
                    case .favorites:
                        let favoriteIds = outline.connectionIds(in: .favorites)
                        ForEach(favoriteIds, id: \.self) { id in
                            connectionRow(connectionsById[id], section: .favorites)
                        }
                        .onMove(perform: canReorder ? reorderFavorites(favoriteIds) : nil)
                    case .recent:
                        ForEach(outline.connectionIds(in: .recent), id: \.self) { id in
                            connectionRow(connectionsById[id], section: .recent)
                        }
                    default:
                        ConnectionTreeLevel(
                            nodes: section.nodes,
                            canReorder: canReorder,
                            isExpanded: { groupExpansion($0, outline: outline) },
                            connectionRow: { connectionRow(connectionsById[$0], section: .connections) },
                            groupLabel: { groupRow(groupsById[$0], count: $1) },
                            reorderGroups: { appState.reorderGroups($0) },
                            reorderConnections: { appState.reorderConnections($0) }
                        )
                    }
                } header: {
                    sectionHeader(section.kind)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if outline.isEmpty && outline.isQueryActive {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .environment(\.editMode, $editMode)
        .searchable(
            text: $searchText,
            tokens: $searchTokens,
            suggestedTokens: .constant(suggestedTokens),
            prompt: Text("Search Connections")
        ) { token in
            Label(token.name, systemImage: "tag")
        }
        .refreshable {
            guard cloudSyncEnabled else { return }
            await appState.syncCoordinator.sync()
        }
        .confirmationDialog(deletionTitle, isPresented: deletionPresented, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) {
                confirmConnectionDeletion()
            }
        } message: {
            if connectionsPendingDeletion.count > 1 {
                Text("Saved credentials for these connections will be permanently removed.")
            } else {
                Text("Are you sure you want to delete this connection? Saved credentials will be permanently removed.")
            }
        }
        .confirmationDialog(
            String(localized: "Delete Group"),
            isPresented: groupDeletionPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let group = groupPendingDeletion {
                    appState.deleteGroup(group.id)
                }
            }
        } message: {
            if let group = groupPendingDeletion,
               !LibraryGroupGraph(groups: appState.groups).descendantIds(of: group.id).isEmpty {
                Text("Its subgroups are deleted too. Their connections move to Ungrouped.")
            } else {
                Text("Connections in this group will be moved to ungrouped.")
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ kind: LibrarySectionKind) -> some View {
        switch kind {
        case .favorites:
            Text("Favorites")
        case .recent:
            HStack {
                Text("Recent")
                Spacer()
                Button("Clear") {
                    appState.libraryPreferences.clearRecent()
                }
                .font(.subheadline)
                .textCase(nil)
            }
        default:
            Text("Connections")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    moveDropped(items, toGroup: nil)
                }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func connectionRow(_ connection: DatabaseConnection?, section: LibrarySectionKind) -> some View {
        if let connection {
            ConnectionListRow(
                model: ConnectionListRowModel(
                    connection: connection,
                    section: section,
                    tags: appState.tags,
                    groups: appState.groups
                ),
                isRenaming: renamingConnectionId == connection.id,
                onOpen: { selectedConnectionIdString = connection.id.uuidString },
                onCommitRename: { commitRename(connection.id, name: $0) },
                onCancelRename: { renamingConnectionId = nil }
            )
            .tag(LibraryRowID.connection(connection.id, section: section))
            .draggable(connection.id.uuidString)
            .swipeActions(edge: .leading) {
                favoriteButton(for: connection)
                    .tint(.yellow)
                Button {
                    activeSheet = .editConnection(connection)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                trailingSwipeAction(for: connection, section: section)
            }
            .contextMenu {
                connectionMenu(for: connection, section: section)
            }
            .renameAction {
                renamingConnectionId = connection.id
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: ConnectionGroup?, count: Int) -> some View {
        if let group {
            ConnectionGroupRowLabel(group: group, connectionCount: count)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    moveDropped(items, toGroup: group.id)
                }
                .contextMenu {
                    Button {
                        activeSheet = .editGroup(group)
                    } label: {
                        Label("Edit Group", systemImage: "pencil")
                    }
                    if LibraryGroupGraph(groups: appState.groups).canCreateSubgroup(under: group.id) {
                        Button {
                            activeSheet = .newGroup(parentId: group.id)
                        } label: {
                            Label("New Subgroup", systemImage: "folder.badge.plus")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        groupPendingDeletion = group
                    } label: {
                        Label("Delete Group", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private func favoriteButton(for connection: DatabaseConnection) -> some View {
        Button {
            appState.setFavorite([connection.id], isFavorite: !connection.isFavorite)
        } label: {
            if connection.isFavorite {
                Label("Remove from Favorites", systemImage: "star.slash")
            } else {
                Label("Add to Favorites", systemImage: "star")
            }
        }
    }

    @ViewBuilder
    private func trailingSwipeAction(for connection: DatabaseConnection, section: LibrarySectionKind) -> some View {
        switch section {
        case .recent:
            Button {
                appState.libraryPreferences.removeFromRecent([connection.id])
            } label: {
                Label("Remove from Recent", systemImage: "clock.badge.xmark")
            }
            .tint(.gray)
        default:
            Button {
                connectionsPendingDeletion = [connection.id]
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    @ViewBuilder
    private func connectionMenu(for connection: DatabaseConnection, section: LibrarySectionKind) -> some View {
        Button {
            selectedConnectionIdString = connection.id.uuidString
        } label: {
            Label("Open", systemImage: "arrow.right.circle")
        }
        Button {
            activeSheet = .editConnection(connection)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        RenameButton()
        Button {
            appState.duplicateConnection(connection)
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }
        Divider()
        favoriteButton(for: connection)
        Button {
            activeSheet = .moveConnections([connection.id])
        } label: {
            Label("Move to Group", systemImage: "folder")
        }
        if section == .recent {
            Button {
                appState.libraryPreferences.removeFromRecent([connection.id])
            } label: {
                Label("Remove from Recent", systemImage: "clock.badge.xmark")
            }
        }
        Divider()
        Button(role: .destructive) {
            connectionsPendingDeletion = [connection.id]
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            moreMenu
            if !appState.connections.isEmpty {
                Button(isEditing ? String(localized: "Done") : String(localized: "Edit")) {
                    withAnimation {
                        editMode = isEditing ? .inactive : .active
                    }
                }
            }
            Button {
                activeSheet = .addConnection
            } label: {
                Image(systemName: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel(Text("Add Connection"))
        }
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                Task {
                    await appState.syncCoordinator.sync()
                }
            } label: {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: cloudSyncEnabled
                        ? "arrow.triangle.2.circlepath.icloud"
                        : "icloud.slash")
                }
            }
            .disabled(isSyncing || !cloudSyncEnabled)
            .accessibilityLabel(Text("Sync with iCloud"))

            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "gear")
            }
            .accessibilityLabel(Text("Settings"))
        }
        if isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                let ids = selectedConnectionIds
                Button("Move") {
                    activeSheet = .moveConnections(ids)
                }
                .disabled(ids.isEmpty)
                Spacer()
                selectionFavoriteButton(ids)
                Spacer()
                Button(String(localized: "Delete"), role: .destructive) {
                    connectionsPendingDeletion = Set(ids)
                }
                .disabled(ids.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func selectionFavoriteButton(_ ids: [UUID]) -> some View {
        let selected = Set(ids)
        let allFavorites = !ids.isEmpty && appState.connections.filter { selected.contains($0.id) }.allSatisfy(\.isFavorite)
        Button {
            appState.setFavorite(selected, isFavorite: !allFavorites)
        } label: {
            if allFavorites {
                Text("Unfavorite")
            } else {
                Text("Favorite")
            }
        }
        .disabled(ids.isEmpty)
    }

    private var moreMenu: some View {
        Menu {
            Picker(selection: sortModeBinding) {
                ForEach(LibrarySortMode.allCases, id: \.self) { mode in
                    Text(mode.mobileTitle).tag(mode)
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)

            if !appState.tags.isEmpty {
                Section("Filter by Tag") {
                    ForEach(appState.tags) { tag in
                        Toggle(isOn: tokenBinding(for: tag)) {
                            Text(verbatim: tag.name)
                        }
                    }
                    if searchTokens.count > 1 {
                        Toggle("Match All Tags", isOn: $matchesAllTags)
                    }
                }
            }

            Section {
                Button {
                    activeSheet = .newGroup(parentId: nil)
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                Button {
                    activeSheet = .groups
                } label: {
                    Label("Manage Groups", systemImage: "folder")
                }
                Button {
                    activeSheet = .tags
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                }
            }

            Section {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Import Connections", systemImage: "square.and.arrow.down")
                }
                Button {
                    activeSheet = .export
                } label: {
                    Label("Export Connections", systemImage: "square.and.arrow.up")
                }
                .disabled(appState.connections.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(Text("More"))
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ConnectionListSheet) -> some View {
        switch sheet {
        case .addConnection:
            ConnectionFormView { connection in
                appState.addConnection(connection)
                activeSheet = nil
            }
        case .editConnection(let connection):
            ConnectionFormView(editing: connection) { updated in
                appState.updateConnection(updated)
                coordinatorStore.invalidate(updated.id)
                activeSheet = nil
            }
        case .moveConnections(let ids):
            MoveToGroupSheet(connectionIds: ids)
        case .newGroup(let parentId):
            GroupFormSheet(parentId: parentId) { group in
                appState.addGroup(group)
            }
        case .editGroup(let group):
            GroupFormSheet(editing: group) { updated in
                appState.updateGroup(updated)
            }
        case .groups:
            GroupManagementView()
        case .tags:
            TagManagementView()
        case .settings:
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            CloseButton {
                                activeSheet = nil
                            }
                        }
                    }
            }
        case .importFile(let url):
            MobileConnectionImportSheet(fileURL: url) { count in
                importResultCount = count
            }
            .environment(appState)
        case .export:
            MobileConnectionExportSheet(connections: appState.connections)
                .environment(appState)
        }
    }

    // MARK: - Bindings

    private var sortModeBinding: Binding<LibrarySortMode> {
        Binding(
            get: { appState.libraryPreferences.sortMode },
            set: { appState.libraryPreferences.setSortMode($0) }
        )
    }

    private func tokenBinding(for tag: ConnectionTag) -> Binding<Bool> {
        Binding(
            get: { searchTokens.contains { $0.id == tag.id } },
            set: { isOn in
                searchTokens.removeAll { $0.id == tag.id }
                guard isOn else { return }
                searchTokens.append(ConnectionTagToken(id: tag.id, name: tag.name))
            }
        )
    }

    private func groupExpansion(_ groupId: UUID, outline: LibraryOutline) -> Binding<Bool> {
        Binding(
            get: {
                outline.groupIdsExpandedByQuery.contains(groupId)
                    || appState.libraryPreferences.isGroupExpanded(groupId)
            },
            set: { appState.libraryPreferences.setGroup(groupId, expanded: $0) }
        )
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { !connectionsPendingDeletion.isEmpty },
            set: { if !$0 { connectionsPendingDeletion = [] } }
        )
    }

    private var groupDeletionPresented: Binding<Bool> {
        Binding(
            get: { groupPendingDeletion != nil },
            set: { if !$0 { groupPendingDeletion = nil } }
        )
    }

    private var deletionTitle: String {
        connectionsPendingDeletion.count > 1
            ? String(format: String(localized: "Delete %d Connections"), connectionsPendingDeletion.count)
            : String(localized: "Delete Connection")
    }

    private var importResultPresented: Binding<Bool> {
        Binding(
            get: { importResultCount != nil },
            set: { if !$0 { importResultCount = nil } }
        )
    }

    private var importResultMessage: String {
        let count = importResultCount ?? 0
        return count == 1
            ? String(localized: "1 connection imported.")
            : String(format: String(localized: "%d connections imported."), count)
    }

    // MARK: - Actions

    private func reorderFavorites(_ ids: [UUID]) -> (IndexSet, Int) -> Void {
        { source, destination in
            var ordered = ids
            ordered.move(fromOffsets: source, toOffset: destination)
            appState.reorderFavorites(ordered)
        }
    }

    private func moveDropped(_ items: [String], toGroup groupId: UUID?) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:))
        let known = Set(appState.connections.map(\.id))
        let moving = ids.filter(known.contains)
        guard !moving.isEmpty else { return false }
        appState.moveConnections(moving, toGroup: groupId)
        return true
    }

    private func commitRename(_ id: UUID, name: String) {
        guard renamingConnectionId == id else { return }
        renamingConnectionId = nil
        appState.renameConnection(id, to: name)
    }

    private func confirmConnectionDeletion() {
        let ids = connectionsPendingDeletion
        if let open = selectedConnectionUUID, ids.contains(open) {
            selectedConnectionIdString = nil
        }
        selection = selection.filter { row in
            guard case .connection(let id, _) = row else { return true }
            return !ids.contains(id)
        }
        appState.removeConnections(ids)
        connectionsPendingDeletion = []
    }

    private func presentPendingImport() {
        guard let url = appState.pendingImportURL else { return }
        appState.pendingImportURL = nil
        activeSheet = .importFile(url)
    }

    private func navigateToPendingConnection(_ id: UUID?) {
        guard let id,
              appState.connections.contains(where: { $0.id == id }) else { return }
        selectedConnectionIdString = id.uuidString
        appState.pendingConnectionId = nil
    }
}
