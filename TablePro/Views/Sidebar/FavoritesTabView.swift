import SwiftUI
import TableProImport

internal struct FavoritesTabView: View {
    @Environment(\.sidebarRowSize) private var systemRowSize

    @State private var viewModel: FavoritesSidebarViewModel
    @State private var favoriteTables: [FavoriteTablesStorage.FavoriteEntry] = []
    @State private var folderToDelete: SQLFavoriteFolder?
    @State private var showDeleteFolderAlert = false
    @State private var linkedFileToTrash: LinkedSQLFavorite?
    @State private var showTrashLinkedFileAlert = false
    @State private var linkedMetadataTarget: LinkedSQLFavorite?
    @State private var linkedFolderToRemove: LinkedSQLFolder?
    @State private var showRemoveLinkedFolderAlert = false
    let connectionId: UUID
    @Bindable private var sharedSidebarState: SharedSidebarState
    let tables: [TableInfo]
    private var coordinator: MainContentCoordinator?

    private var searchText: String { sharedSidebarState.favoritesSearchText }
    private var activeDatabase: String? {
        let name = coordinator?.browseDatabaseName ?? ""
        return name.isEmpty ? nil : name
    }

    private var availableFavoriteTables: [TableInfo] {
        let database = activeDatabase
        let tablesByKey = Dictionary(
            tables.map { (Self.tableKey(schema: $0.schema, name: $0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return favoriteTables.compactMap { entry in
            guard entry.database == database else { return nil }
            return tablesByKey[Self.tableKey(schema: entry.schema, name: entry.name)]
        }
    }

    private static func tableKey(schema: String?, name: String) -> String {
        "\(schema ?? "")\u{1}\(name)"
    }

    init(connectionId: UUID, sharedSidebarState: SharedSidebarState, tables: [TableInfo], coordinator: MainContentCoordinator?) {
        self.connectionId = connectionId
        self.sharedSidebarState = sharedSidebarState
        self.tables = tables
        _viewModel = State(wrappedValue: FavoritesSidebarViewModel(connectionId: connectionId))
        self.coordinator = coordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                let items = viewModel.filteredNodes(searchText: searchText)
                let filteredTables = searchText.isEmpty
                    ? availableFavoriteTables
                    : availableFavoriteTables.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

                if !viewModel.isInitialLoadComplete && viewModel.nodes.isEmpty && filteredTables.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.nodes.isEmpty && filteredTables.isEmpty && teamLibraryQueries.isEmpty && searchText.isEmpty {
                    emptyState
                } else if items.isEmpty && filteredTables.isEmpty && teamLibraryQueries.isEmpty {
                    noMatchState
                } else {
                    favoritesList(items, filteredTables: filteredTables)
                }
            }
        }
        .onAppear {
            viewModel.startWatchingLinkedFolders()
            favoriteTables = viewModel.favoriteTables(for: connectionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoriteTablesDidChange)) { _ in
            favoriteTables = viewModel.favoriteTables(for: connectionId)
        }
        .sheet(item: $viewModel.editDialogItem) { item in
            FavoriteEditDialog(
                connectionId: connectionId,
                favorite: item.favorite,
                initialQuery: item.query,
                folderId: item.folderId,
                folders: viewModel.nodes.collectFolders()
            )
        }
        .alert(
            String(localized: "Delete Folder?"),
            isPresented: $showDeleteFolderAlert,
            presenting: folderToDelete
        ) { folder in
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteFolder(folder)
            }
        } message: { folder in
            Text(String(format: String(localized: "The folder \"%@\" will be deleted. Items inside will be moved to the parent level."), folder.name))
        }
        .sheet(item: $linkedMetadataTarget) { file in
            LinkedFavoriteMetadataDialog(
                favorite: file,
                connectionId: connectionId,
                onSaved: {}
            )
        }
        .alert(
            String(localized: "Remove Linked Folder?"),
            isPresented: $showRemoveLinkedFolderAlert,
            presenting: linkedFolderToRemove
        ) { folder in
            Button(String(localized: "Cancel"), role: .cancel) {
                linkedFolderToRemove = nil
            }
            Button(String(localized: "Remove"), role: .destructive) {
                viewModel.removeLinkedFolder(folder)
                linkedFolderToRemove = nil
            }
        } message: { folder in
            Text(String(format: String(localized: "\"%@\" will be removed from the sidebar. Files on disk will not be deleted."), folder.name))
        }
        .alert(
            String(localized: "Move File to Trash?"),
            isPresented: $showTrashLinkedFileAlert,
            presenting: linkedFileToTrash
        ) { file in
            Button(String(localized: "Cancel"), role: .cancel) {
                linkedFileToTrash = nil
            }
            Button(String(localized: "Move to Trash"), role: .destructive) {
                coordinator?.trashLinkedFavorite(file)
                viewModel.reloadLinkedFolders()
                linkedFileToTrash = nil
            }
        } message: { file in
            Text(String(format: String(localized: "\"%@\" will be moved to Trash. You can recover it from there."), file.name))
        }
        .alert(String(localized: "Delete Favorite?"), isPresented: $viewModel.showDeleteConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {
                viewModel.favoritesToDelete = []
            }
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.confirmDeleteFavorites()
            }
        } message: {
            let count = viewModel.favoritesToDelete.count
            if count == 1 {
                Text(String(format: String(localized: "\"%@\" will be permanently deleted."), viewModel.favoritesToDelete.first?.name ?? ""))
            } else {
                Text(String(format: String(localized: "%d favorites will be permanently deleted."), count))
            }
        }
    }

    // MARK: - List

    private var teamLibraryQueries: [TeamLibraryPullResponse.Query] {
        guard LicenseManager.shared.isFeatureAvailable(.teamLibrary) else { return [] }
        let all = TeamLibrarySyncCoordinator.shared.library.queries
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.query.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func teamFavorite(from query: TeamLibraryPullResponse.Query) -> SQLFavorite {
        SQLFavorite(
            id: UUID(),
            name: query.name,
            query: query.query,
            keyword: nil,
            folderId: nil,
            connectionId: nil,
            sortOrder: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func publishSavedQueriesToTeam() {
        Task { @MainActor in
            let favorites = await SQLFavoriteManager.shared.fetchFavorites()
            let folders = await SQLFavoriteManager.shared.fetchFolders()
            guard !favorites.isEmpty else {
                presentTeamLibraryInfo(String(localized: "You have no saved queries to publish."))
                return
            }
            guard await confirmPublishSavedQueries(count: favorites.count) else { return }
            do {
                _ = try await TeamLibrarySyncCoordinator.shared.publish(connections: [], favorites: favorites, folders: folders)
                presentTeamLibraryInfo(String(format: String(localized: "Published %d saved queries to your team."), favorites.count))
            } catch {
                presentTeamLibraryInfo(error.localizedDescription)
            }
        }
    }

    private func confirmPublishSavedQueries(count: Int) async -> Bool {
        await AlertHelper.confirmDestructive(
            title: String(localized: "Publish saved queries to your team?"),
            message: String(
                format: String(localized: "Your team will see the names and SQL of %d saved queries. This replaces what you previously published."),
                count
            ),
            confirmButton: String(localized: "Publish"),
            window: nil
        )
    }

    private func presentTeamLibraryInfo(_ message: String) {
        AlertHelper.showInfoSheet(
            title: String(localized: "Team Library"),
            message: message,
            window: nil
        )
    }

    /// The Favorites list is an `NSOutlineView`. A SwiftUI `List` here drew no emphasized selection
    /// and answered no arrow key, because the app hosts it in a bare `NSHostingController` with no
    /// SwiftUI scene above it. Rows, menus and actions stay exactly where they were; only the list
    /// container changed.
    private func favoritesList(
        _ items: [FavoriteNode],
        filteredTables: [TableInfo]
    ) -> some View {
        FavoritesOutlineView(
            input: FavoritesOutlineInput(
                connectionId: connectionId,
                activeDatabase: activeDatabase,
                tables: filteredTables,
                queryNodes: items,
                teamQueries: teamLibraryQueries.map {
                    FavoritesOutlineTeamQuery(id: $0.id, name: $0.name, publishedBy: $0.publishedBy)
                },
                renamingFolderId: viewModel.renamingFolderId,
                allFolders: viewModel.nodes.collectFolders(),
                teamLibraryAvailable: LicenseManager.shared.isFeatureAvailable(.teamLibrary)
            ),
            selection: $sharedSidebarState.selectedFavorite,
            rowSizePreference: AppSettingsManager.shared.general.sidebarRowSize,
            actions: FavoritesOutlineActions(
                primaryAction: { handlePrimaryAction($0) },
                deleteSelection: { deleteNode($0) },
                commitRename: { folder, name in viewModel.commitRenameFolder(folder, to: name) },
                cancelRename: { viewModel.renamingFolderId = nil },
                performMenuCommand: { perform($0) }
            ),
            row: { outlineRow($0) }
        )
    }

    /// The cell pins its hosted view to the full row width, and `NSHostingView` centers a root view
    /// narrower than its bounds, so the row has to claim that width itself or short content drifts
    /// to the middle.
    private func outlineRow(_ node: FavoritesOutlineNode) -> some View {
        rowContent(node)
            .font(resolvedRowSize.rowFont)
            .imageScale(.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// AppKit sizes the row from `rowSizeStyle`, but it does that by laying out
    /// `NSTableCellView.textField`, and these cells host SwiftUI instead. Without this the object
    /// list grew with the sidebar size and the Favorites list beside it did not.
    private var resolvedRowSize: SidebarRowSize {
        SidebarRowSizeResolver.resolve(
            preference: AppSettingsManager.shared.general.sidebarRowSize,
            system: systemRowSize
        )
    }

    /// No `.contextMenu` on any row: the outline view owns the menu, so AppKit sets `clickedRow`,
    /// highlights the clicked row and answers a right-click below the last one.
    @ViewBuilder
    private func rowContent(_ node: FavoritesOutlineNode) -> some View {
        switch node.kind {
        case .header(let title):
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .table(let table):
            favoriteTableRow(table: table)
        case .query(let favoriteNode):
            favoriteQueryRow(favoriteNode)
        case .teamQuery(_, let name, let publishedBy):
            teamQueryRow(name: name, publishedBy: publishedBy)
        }
    }

    @ViewBuilder
    private func favoriteQueryRow(_ node: FavoriteNode) -> some View {
        switch node.content {
        case .favorite(let favorite):
            FavoriteRowView(favorite: favorite)
        case .folder(let folder):
            Label(folder.name, systemImage: "folder")
        case .linkedFolder(let folder):
            LinkedFolderRowLabel(folder: folder)
        case .linkedSubfolder(_, let displayName, _):
            LinkedSubfolderRowLabel(displayName: displayName)
        case .linkedFavorite(let linked):
            LinkedFavoriteRowView(favorite: linked)
        }
    }

    /// One line, not two. The outline draws a uniform 24pt row, and the stacked publisher caption
    /// the SwiftUI list used would be clipped.
    private func teamQueryRow(name: String, publishedBy: String?) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(name)
                    .lineLimit(1)
                if let publishedBy {
                    Text(publishedBy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: "books.vertical")
                .foregroundStyle(.secondary)
        }
    }

    private func favoriteTableRow(table: TableInfo) -> some View {
        Label {
            Text(table.name)
        } icon: {
            Image(systemName: TableRowLogic.iconName(for: table.type))
                .selectionAwareTint(Color.accentColor)
        }
        .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
        .accessibilityLabel(
            TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false)
        )
    }

    @ViewBuilder
    private func favoriteTableContextMenu(_ table: TableInfo) -> some View {
        Button(String(localized: "Open Table")) {
            coordinator?.openTableTab(table, activateGridFocus: true)
        }

        Button(String(localized: "Show ER Diagram")) {
            coordinator?.showERDiagram()
        }

        Divider()

        Button(role: .destructive) {
            FavoriteTablesStorage.shared.removeFavorite(name: table.name, schema: table.schema, database: activeDatabase, connectionId: connectionId)
        } label: {
            Text(String(localized: "Remove from Favorites"))
        }
    }

    private func handlePrimaryAction(_ kind: FavoritesOutlineNode.Kind) {
        switch kind {
        case .header:
            break
        case .table(let table):
            coordinator?.openTableTab(table, activateGridFocus: true)
        case .query(let node):
            switch node.content {
            case .favorite(let favorite):
                coordinator?.insertFavorite(favorite)
            case .linkedFavorite(let linked):
                coordinator?.openLinkedFavorite(linked)
            case .folder, .linkedFolder, .linkedSubfolder:
                break
            }
        case .teamQuery(let id, _, _):
            guard let query = TeamLibrarySyncCoordinator.shared.library.queries.first(where: { $0.id == id })
            else { return }
            coordinator?.runFavoriteInNewTab(teamFavorite(from: query))
        }
    }

    private func deleteNode(_ kind: FavoritesOutlineNode.Kind) {
        switch kind {
        case .header, .teamQuery:
            break
        case .table(let table):
            FavoriteTablesStorage.shared.removeFavorite(
                name: table.name, schema: table.schema, database: activeDatabase, connectionId: connectionId
            )
        case .query(let node):
            switch node.content {
            case .favorite(let favorite):
                viewModel.deleteFavorite(favorite)
            case .linkedFavorite(let linked):
                linkedFileToTrash = linked
                showTrashLinkedFileAlert = true
            case .folder, .linkedFolder, .linkedSubfolder:
                break
            }
        }
    }

    // MARK: - Menu commands

    /// Runs what a contextual menu item described. The commands that end in a confirmation set the
    /// state this view already owns, so the alert stays where the rest of the presentation is.
    private func perform(_ command: FavoritesMenuCommand) {
        switch command {
        case .openTable(let table):
            coordinator?.openTableTab(table, activateGridFocus: true)
        case .showERDiagram:
            coordinator?.showERDiagram()
        case .removeTableFavorite(let table):
            viewModel.removeTableFavorite(table, database: activeDatabase)
        case .insertFavorite(let favorite):
            coordinator?.insertFavorite(favorite)
        case .runFavoriteInNewTab(let favorite):
            coordinator?.runFavoriteInNewTab(favorite)
        case .copyText(let text):
            ClipboardService.shared.writeText(text)
        case .editFavorite(let favorite):
            viewModel.editFavorite(favorite)
        case .moveFavorite(let id, let folderId):
            viewModel.moveFavorite(id: id, toFolder: folderId)
            if let folderId {
                FavoritesExpansionState.shared.setFolderExpanded(folderId, expanded: true, for: connectionId)
            }
        case .deleteFavorite(let favorite):
            viewModel.deleteFavorite(favorite)
        case .openLinkedFavorite(let favorite):
            coordinator?.openLinkedFavorite(favorite)
        case .editLinkedMetadata(let favorite):
            linkedMetadataTarget = favorite
        case .copyLinkedFavoriteQuery(let favorite):
            guard let loaded = FileTextLoader.load(favorite.fileURL) else { return }
            ClipboardService.shared.writeText(loaded.content)
        case .revealLinkedFavorite(let favorite):
            coordinator?.revealLinkedFavoriteInFinder(favorite)
        case .trashLinkedFavorite(let favorite):
            linkedFileToTrash = favorite
            showTrashLinkedFileAlert = true
        case .revealLinkedFolder(let folder):
            viewModel.revealLinkedFolder(folder)
        case .setLinkedFolderEnabled(let folder, let isEnabled):
            viewModel.setLinkedFolder(folder, enabled: isEnabled)
        case .reloadLinkedFolders:
            viewModel.reloadLinkedFolders()
        case .addLinkedFolder:
            addLinkedFolder()
        case .removeLinkedFolder(let folder):
            linkedFolderToRemove = folder
            showRemoveLinkedFolderAlert = true
        case .renameFolder(let folder):
            viewModel.startRenameFolder(folder)
        case .newFavorite(let folderId):
            viewModel.createFavorite(folderId: folderId)
        case .newFolder(let parentId):
            viewModel.createFolder(parentId: parentId)
        case .deleteFolder(let folder):
            folderToDelete = folder
            showDeleteFolderAlert = true
        case .newQuery:
            coordinator?.commandActions?.newTab()
        case .publishSavedQueriesToTeam:
            publishSavedQueriesToTeam()
        }
    }

    // MARK: - Empty States

    /// An empty list has no row to right-click, so the commands the background menu carries have to
    /// be here too. They used to live in a bar at the bottom of the sidebar.
    ///
    /// The actions are stacked, not left to `ContentUnavailableView`'s default row. On macOS 15 the
    /// row of three buttons is wider than the sidebar, and the view sizes its whole content to that
    /// row, so the description and the buttons ran past both edges and were cut off.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Favorites"), systemImage: "star")
        } description: {
            Text("Save frequently used queries, or link a folder of .sql files to share with your team.")
        } actions: {
            VStack(spacing: 8) {
                Button(String(localized: "New Favorite...")) {
                    viewModel.createFavorite()
                }
                Button(String(localized: "New Folder")) {
                    viewModel.createFolder()
                }
                Button(String(localized: "Link a Folder...")) {
                    addLinkedFolder()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addLinkedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder containing .sql files")

        guard let window = AlertHelper.resolveWindow(nil) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard case .alreadyLinked(let name) = viewModel.addLinkedFolder(at: url) else { return }
                AlertHelper.showInfoSheet(
                    title: String(localized: "This folder is already linked"),
                    message: String(format: String(localized: "%@ is already in the favorites list."), name),
                    window: window
                )
            }
        }
    }
}
