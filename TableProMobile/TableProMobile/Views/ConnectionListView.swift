import CloudKit
import SwiftUI
import TableProConnectionLibrary
import TableProImport
import TableProModels
import TableProSyncTransport
import TipKit
import UniformTypeIdentifiers

nonisolated struct ConnectionTagToken: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
}

struct ConnectionListView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLockState.self) private var lockState
    @Environment(ConnectionCoordinatorStore.self) private var coordinatorStore
    @Environment(ScenePresenter.self) private var presenter
    @SceneStorage("lastConnectionId") private var selectedConnectionIdString: String?

    @State private var searchText = ""
    @State private var searchTokens: [ConnectionTagToken] = []
    @State private var matchesAllTags = false
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<LibraryRowID> = []
    @State private var renamingRow: LibraryRowID?
    @State private var connectionsPendingDeletion: Set<UUID> = []
    @State private var groupPendingDeletion: ConnectionGroup?
    @State private var isConfirmingSampleReset = false
    @State private var showingFileImporter = false
    @State private var importAfterCoverDismissal: URL?
    @State private var importResultCount: Int?
    @State private var actionErrorMessage: String?
    @State private var iCloudAccountAvailable = false
    @State private var tips = ConnectionListTips.makeGroup()

    private var selectedConnectionUUID: UUID? {
        selectedConnectionIdString.flatMap { UUID(uuidString: $0) }
    }

    private var openConnection: Binding<DatabaseConnection?> {
        Binding(
            get: {
                guard !presenter.holdsConnectionRestore, let id = selectedConnectionUUID else { return nil }
                return coordinatorStore.presentedRecord(for: id, in: appState.connections)
            },
            set: { selectedConnectionIdString = $0?.id.uuidString }
        )
    }

    private var isSyncEnabled: Bool {
        appState.onboarding.isCloudSyncEnabled
    }

    private var isEditing: Bool {
        editMode == .active
    }

    private var hasLibraryItems: Bool {
        !appState.connections.isEmpty || !appState.groups.isEmpty
    }

    private var listState: ConnectionListState {
        ConnectionListState.resolve(
            loadStatus: appState.loadStatus,
            hasLibraryItems: hasLibraryItems,
            isSyncEnabled: isSyncEnabled,
            syncStatus: appState.syncCoordinator.status,
            hasCompletedFirstSync: appState.syncCoordinator.hasCompletedFirstSync
        )
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

    private var tipInputs: [Int] {
        [
            appState.onboarding.hasSeenWelcome && presenter.sheet == nil ? 1 : 0,
            appState.connections.count,
            appState.connections.contains(where: \.isFavorite) ? 1 : 0,
            appState.connections.contains { !$0.tagIds.isEmpty } ? 1 : 0
        ]
    }

    var body: some View {
        @Bindable var presenter = presenter
        NavigationStack {
            content
                .navigationTitle("Connections")
                .toolbar { toolbarContent }
                .onChange(of: editMode) { _, mode in
                    guard mode == .inactive else { return }
                    selection = []
                }
                .onChange(of: hasLibraryItems) { _, hasItems in
                    guard !hasItems else { return }
                    editMode = .inactive
                    selection = []
                }
                .onChange(of: appState.tags) { _, tags in
                    let known = Set(tags.map(\.id))
                    searchTokens.removeAll { !known.contains($0.id) }
                }
                .onChange(of: searchTokens) { _, tokens in
                    guard !tokens.isEmpty else { return }
                    ConnectionListTips.tagFilterUsed()
                }
                .task(id: tipInputs) {
                    ConnectionListTips.libraryChanged(
                        isListReady: tipInputs[0] == 1,
                        connectionCount: tipInputs[1],
                        hasFavorites: tipInputs[2] == 1,
                        hasTaggedConnections: tipInputs[3] == 1
                    )
                }
                .task(id: isSyncEnabled) {
                    guard !isSyncEnabled else { return }
                    iCloudAccountAvailable = await appState.syncCoordinator.accountStatus() == .available
                }
                .task {
                    clearUnknownSelection()
                    presenter.beginLaunch(with: appState)
                    deliverPendingIntent()
                }
        }
        .fullScreenCover(item: openConnection, onDismiss: connectionCoverDidDismiss) { connection in
            ConnectedView(connection: connection)
                .id(connection.id)
        }
        .sheet(item: $presenter.sheet, onDismiss: sheetDidDismiss) { sheet in
            sheetContent(sheet)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.tableproConnectionShare],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            presenter.present(.importFile(url))
        }
        .onChange(of: presenter.pendingIntent) { _, _ in
            deliverPendingIntent()
        }
        .onChange(of: presenter.holdsConnectionRestore) { _, _ in
            deliverPendingIntent()
        }
        .onChange(of: presenter.isHeldByEditor) { _, _ in
            deliverPendingIntent()
        }
        .onChange(of: lockState.isLocked) { _, _ in
            deliverPendingIntent()
        }
        .onChange(of: appState.loadStatus) { _, _ in
            clearUnknownSelection()
            deliverPendingIntent()
        }
        .onChange(of: appState.connections) { _, _ in
            clearUnknownSelection()
        }
        .alert(importResultMessage, isPresented: importResultPresented) {
            Button(String(localized: "OK")) { importResultCount = nil }
        }
        .alert(
            String(localized: "Sample Database Unavailable"),
            isPresented: actionErrorPresented
        ) {
            Button(String(localized: "OK")) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch listState {
        case .content(let syncProblem):
            libraryList(syncProblem: syncProblem)
        default:
            ConnectionListStatusView(state: listState, actions: emptyActions)
        }
    }

    private var emptyActions: ConnectionListEmptyActions {
        ConnectionListEmptyActions(
            addConnection: { presenter.present(.addConnection) },
            openSample: openSampleDatabase,
            turnOnICloud: !isSyncEnabled && iCloudAccountAvailable ? { appState.setCloudSyncEnabled(true) } : nil,
            importConnections: { showingFileImporter = true },
            retrySync: { Task { await appState.syncCoordinator.sync() } },
            retryLoad: { appState.retryLoadIfFailed() }
        )
    }

    private func libraryList(syncProblem: SyncError?) -> some View {
        let outline = outline
        let connectionsById = Dictionary(appState.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupsById = Dictionary(appState.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let canReorder = appState.libraryPreferences.sortMode == .manual && !outline.isQueryActive

        return List(selection: $selection) {
            if let syncProblem {
                Section {
                    ConnectionListSyncProblemRow(error: syncProblem) {
                        Task { await appState.syncCoordinator.sync() }
                    }
                }
            }
            if !outline.isQueryActive, !isEditing, let tip = tips.currentTip {
                Section {
                    TipView(tip)
                }
            }
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
        .modifier(SyncRefreshModifier(isEnabled: isSyncEnabled) {
            await appState.syncCoordinator.sync()
        })
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
        .confirmationDialog(
            String(localized: "Reset Sample Database?"),
            isPresented: $isConfirmingSampleReset,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Reset"), role: .destructive) {
                resetSampleDatabase()
            }
        } message: {
            Text("Every change you made to the sample database is replaced with the original data.")
        }
    }

    @ViewBuilder
    private func sectionHeader(_ kind: LibrarySectionKind) -> some View {
        switch kind {
        case .favorites:
            Text("Favorites")
        case .recent:
            Text("Recent")
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
            let rowId = LibraryRowID.connection(connection.id, section: section)
            ConnectionListRow(
                model: ConnectionListRowModel(
                    connection: connection,
                    section: section,
                    tags: appState.tags,
                    groups: appState.groups
                ),
                isRenaming: renamingRow == rowId,
                onOpen: { open(connection.id) },
                onCommitRename: { commitRename(rowId, connectionId: connection.id, name: $0) },
                onCancelRename: { renamingRow = nil }
            )
            .tag(rowId)
            .draggable(connection.id.uuidString)
            .swipeActions(edge: .leading) {
                favoriteButton(for: connection)
                    .tint(.yellow)
                if !connection.isSample {
                    Button {
                        presenter.present(.editConnection(connection))
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                trailingSwipeAction(for: connection, section: section)
            }
            .contextMenu {
                connectionMenu(for: connection, section: section)
            }
            .renameAction {
                ConnectionListTips.connectionMenuUsed()
                renamingRow = rowId
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
                .swipeActions(edge: .leading) {
                    Button {
                        presenter.present(.editGroup(group))
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        groupPendingDeletion = group
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button {
                        presenter.present(.editGroup(group))
                    } label: {
                        Label("Edit Group", systemImage: "pencil")
                    }
                    if LibraryGroupGraph(groups: appState.groups).canCreateSubgroup(under: group.id) {
                        Button {
                            presenter.present(.newGroup(parentId: group.id))
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
                .accessibilityAction(named: Text("Delete Group")) {
                    groupPendingDeletion = group
                }
        }
    }

    @ViewBuilder
    private func favoriteButton(for connection: DatabaseConnection) -> some View {
        Button {
            appState.setFavorite([connection.id], isFavorite: !connection.isFavorite)
            if !connection.isFavorite {
                ConnectionListTips.favoriteSet()
            }
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
            open(connection.id)
        } label: {
            Label("Open", systemImage: "arrow.right.circle")
        }
        if !connection.isSample {
            Button {
                ConnectionListTips.connectionMenuUsed()
                presenter.present(.editConnection(connection))
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
        }
        RenameButton()
        if !connection.isSample {
            Button {
                ConnectionListTips.connectionMenuUsed()
                appState.duplicateConnection(connection)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
        }
        Divider()
        favoriteButton(for: connection)
        Button {
            ConnectionListTips.connectionMenuUsed()
            presenter.present(.moveConnections([connection.id]))
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
        if connection.isSample {
            Button {
                isConfirmingSampleReset = true
            } label: {
                Label("Reset Database", systemImage: "arrow.counterclockwise")
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
        ToolbarItem(placement: .topBarLeading) {
            Button {
                presenter.present(.settings)
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            moreMenu
            if hasLibraryItems {
                Button(isEditing ? String(localized: "Done") : String(localized: "Edit")) {
                    withAnimation {
                        editMode = isEditing ? .inactive : .active
                    }
                }
            }
            Button {
                presenter.present(.addConnection)
            } label: {
                Label("Add Connection", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!appState.isLibraryWritable)
        }
        if isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                let ids = selectedConnectionIds
                Button("Move") {
                    presenter.present(.moveConnections(ids))
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

            if searchTokens.count > 1 {
                Toggle("Match All Tags", isOn: $matchesAllTags)
            }

            Section {
                Button {
                    presenter.present(.newGroup(parentId: nil))
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                Button {
                    presenter.present(.tags)
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                }
            }
            .disabled(!appState.isLibraryWritable)

            Section {
                Button(action: openSampleDatabase) {
                    Label("Open Sample Database", systemImage: "music.note.list")
                }
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Import Connections", systemImage: "square.and.arrow.down")
                }
                .disabled(!appState.isLibraryWritable)
                Button {
                    presenter.present(.export)
                } label: {
                    Label("Export Connections", systemImage: "square.and.arrow.up")
                }
                .disabled(!appState.connections.contains(where: \.participatesInSync))
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: SceneSheet) -> some View {
        switch sheet {
        case .firstRun(let pages):
            FirstRunSheet(pages: pages)
        case .whatsNew(let version):
            WhatsNewSheet(version: version)
        case .addConnection:
            ConnectionFormView { _ in
                presenter.sheet = nil
            }
        case .editConnection(let connection):
            ConnectionFormView(editing: connection) { _ in
                presenter.sheet = nil
            }
        case .moveConnections(let ids):
            MoveToGroupSheet(connectionIds: ids)
        case .newGroup(let parentId):
            GroupFormSheet(parentId: parentId)
        case .editGroup(let group):
            GroupFormSheet(editing: group)
        case .tags:
            TagManagementView()
        case .settings:
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            CloseButton {
                                presenter.sheet = nil
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
            MobileConnectionExportSheet(connections: appState.connections.filter(\.participatesInSync))
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

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )
    }

    private var importResultMessage: String {
        let count = importResultCount ?? 0
        return count == 1
            ? String(localized: "1 connection imported.")
            : String(format: String(localized: "%d connections imported."), count)
    }

    // MARK: - Actions

    private func open(_ connectionId: UUID) {
        ConnectionListTips.connectionOpened()
        selectedConnectionIdString = connectionId.uuidString
    }

    private func openSampleDatabase() {
        do {
            let sampleId = try appState.openSampleDatabase()
            presenter.requestTable(SampleDatabaseInstaller.startingTable, in: sampleId)
            open(sampleId)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func resetSampleDatabase() {
        Task {
            do {
                try await appState.resetSampleDatabase()
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

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

    private func commitRename(_ rowId: LibraryRowID, connectionId: UUID, name: String) {
        guard renamingRow == rowId else { return }
        renamingRow = nil
        appState.renameConnection(connectionId, to: name)
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

    private func sheetDidDismiss() {
        presenter.sheetDidDismiss(appState: appState)
        deliverPendingIntent()
    }

    private func deliverPendingIntent() {
        guard let intent = presenter.takeDeliverableIntent(
            isLocked: lockState.isLocked,
            isLibraryWritable: appState.isLibraryWritable
        ) else { return }
        switch intent {
        case .openConnection(let connectionId, let table):
            guard appState.connections.contains(where: { $0.id == connectionId }) else { return }
            presenter.requestTable(table, in: connectionId)
            open(connectionId)
        case .importConnections(let url):
            guard selectedConnectionUUID != nil else {
                presenter.present(.importFile(url))
                return
            }
            importAfterCoverDismissal = url
            selectedConnectionIdString = nil
        }
    }

    private func clearUnknownSelection() {
        guard appState.loadStatus == .ready,
              let id = selectedConnectionUUID,
              coordinatorStore.presentedRecord(for: id, in: appState.connections) == nil else { return }
        selectedConnectionIdString = nil
    }

    private func connectionCoverDidDismiss() {
        presenter.dismissConnectionEditor()
        coordinatorStore.discardRemovedRecords()
        presentImportAfterCoverDismissal()
    }

    private func presentImportAfterCoverDismissal() {
        guard let url = importAfterCoverDismissal else { return }
        importAfterCoverDismissal = nil
        presenter.present(.importFile(url))
    }
}

private struct SyncRefreshModifier: ViewModifier {
    let isEnabled: Bool
    let refresh: @Sendable () async -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.refreshable(action: refresh)
        } else {
            content
        }
    }
}
