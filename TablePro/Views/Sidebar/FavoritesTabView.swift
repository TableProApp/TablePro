import SwiftUI
import TableProImport

internal struct FavoritesTabView: View {
    @State private var viewModel: FavoritesSidebarViewModel
    @State private var favoriteTables: [FavoriteTablesStorage.FavoriteEntry] = []
    @State private var folderToDelete: SQLFavoriteFolder?
    @State private var showDeleteFolderAlert = false
    @State private var linkedFileToTrash: LinkedSQLFavorite?
    @State private var showTrashLinkedFileAlert = false
    @State private var linkedMetadataTarget: LinkedSQLFavorite?
    @State private var linkedFolderToRemove: LinkedSQLFolder?
    @State private var showRemoveLinkedFolderAlert = false
    @FocusState private var isRenameFocused: Bool
    let connectionId: UUID
    @Bindable private var sharedSidebarState: SharedSidebarState
    let tables: [TableInfo]
    private var coordinator: MainContentCoordinator?

    private var searchText: String { sharedSidebarState.favoritesSearchText }
    private var activeDatabase: String? {
        let name = coordinator?.activeDatabaseName ?? ""
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
                } else if viewModel.nodes.isEmpty && filteredTables.isEmpty && searchText.isEmpty {
                    emptyState
                } else if items.isEmpty && filteredTables.isEmpty {
                    noMatchState
                } else {
                    favoritesList(items, filteredTables: filteredTables)
                }
            }

            VStack(spacing: 0) {
                Divider()
                bottomToolbar
            }
        }
        .onAppear {
            SQLFolderWatcher.shared.start()
            favoriteTables = FavoriteTablesStorage.shared.favorites(for: connectionId).sorted { $0.name < $1.name }
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoriteTablesDidChange)) { _ in
            favoriteTables = FavoriteTablesStorage.shared.favorites(for: connectionId).sorted { $0.name < $1.name }
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
                LinkedSQLFolderStorage.shared.removeFolder(folder)
                SQLFolderWatcher.shared.reload()
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
                SQLFolderWatcher.shared.reload()
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

    private func favoritesList(
        _ items: [FavoriteNode],
        filteredTables: [TableInfo]
    ) -> some View {
        List(selection: $sharedSidebarState.selectedFavorite) {
            if !filteredTables.isEmpty {
                Section(String(localized: "Tables")) {
                    ForEach(filteredTables) { table in
                        favoriteTableRow(table: table)
                    }
                }
            }
            if !items.isEmpty {
                Section(String(localized: "Queries")) {
                    ForEach(items) { node in
                        FavoriteNodeRow(
                            node: node,
                            connectionId: connectionId,
                            viewModel: viewModel,
                            isRenameFocused: $isRenameFocused
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            deleteSelectedNode()
        }
        .contextMenu(forSelectionType: FavoriteSelection.self) { selection in
            if let selected = selection.first {
                contextMenu(for: selected)
            }
        } primaryAction: { selection in
            guard let selected = selection.first else { return }
            handlePrimaryAction(selected)
        }
    }

    private func favoriteTableRow(table: TableInfo) -> some View {
        Label {
            Text(table.name)
        } icon: {
            Image(systemName: TableRowLogic.iconName(for: table.type))
                .sidebarTint(Color.accentColor)
        }
        .tag(FavoriteSelection.table(database: activeDatabase, schema: table.schema, name: table.name))
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

    private func favoriteTable(database: String?, schema: String?, name: String) -> TableInfo? {
        guard database == activeDatabase else { return nil }
        return availableFavoriteTables.first { $0.name == name && $0.schema == schema }
    }

    @ViewBuilder
    private func contextMenu(for selection: FavoriteSelection) -> some View {
        switch selection {
        case .table(let database, let schema, let name):
            if let table = favoriteTable(database: database, schema: schema, name: name) {
                favoriteTableContextMenu(table)
            }
        case .node(let id):
            if let node = viewModel.node(forId: id) {
                switch node.content {
                case .favorite(let favorite):
                    favoriteContextMenu(favorite)
                case .linkedFavorite(let linked):
                    linkedFavoriteContextMenu(linked)
                case .folder(let folder):
                    folderContextMenu(folder)
                case .linkedFolder(let folder):
                    linkedFolderContextMenu(folder)
                case .linkedSubfolder:
                    EmptyView()
                }
            }
        }
    }

    private func handlePrimaryAction(_ selection: FavoriteSelection) {
        switch selection {
        case .table(let database, let schema, let name):
            if let table = favoriteTable(database: database, schema: schema, name: name) {
                coordinator?.openTableTab(table, activateGridFocus: true)
            }
        case .node(let id):
            guard let node = viewModel.node(forId: id) else { return }
            switch node.content {
            case .favorite(let favorite):
                coordinator?.insertFavorite(favorite)
            case .linkedFavorite(let linked):
                coordinator?.openLinkedFavorite(linked)
            case .folder, .linkedFolder, .linkedSubfolder:
                break
            }
        }
    }

    private func deleteSelectedNode() {
        guard let selection = sharedSidebarState.selectedFavorite else { return }
        switch selection {
        case .table(let database, let schema, let name):
            if let table = favoriteTable(database: database, schema: schema, name: name) {
                FavoriteTablesStorage.shared.removeFavorite(
                    name: table.name, schema: table.schema, database: activeDatabase, connectionId: connectionId
                )
            }
        case .node(let id):
            guard let node = viewModel.node(forId: id) else { return }
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

    // MARK: - Context Menus

    @ViewBuilder
    private func favoriteContextMenu(_ favorite: SQLFavorite) -> some View {
        Button(String(localized: "Insert in Editor")) {
            coordinator?.insertFavorite(favorite)
        }

        Button(String(localized: "Run in New Tab")) {
            coordinator?.runFavoriteInNewTab(favorite)
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(favorite.query, forType: .string)
        } label: {
            Label(String(localized: "Copy Query"), systemImage: "doc.on.doc")
        }

        Button(String(localized: "Edit...")) {
            viewModel.editFavorite(favorite)
        }

        let allFolders = viewModel.nodes.collectFolders()
        if !allFolders.isEmpty {
            Menu(String(localized: "Move to")) {
                if favorite.folderId != nil {
                    Button(String(localized: "Root Level")) {
                        viewModel.moveFavorite(id: favorite.id, toFolder: nil)
                    }

                    Divider()
                }

                ForEach(allFolders) { folder in
                    if folder.id != favorite.folderId {
                        Button(folder.name) {
                            viewModel.moveFavorite(id: favorite.id, toFolder: folder.id)
                            FavoritesExpansionState.shared.setFolderExpanded(folder.id, expanded: true, for: connectionId)
                        }
                    }
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            viewModel.deleteFavorite(favorite)
        } label: {
            Text(String(localized: "Delete"))
        }
    }

    @ViewBuilder
    private func linkedFavoriteContextMenu(_ favorite: LinkedSQLFavorite) -> some View {
        Button(String(localized: "Open in Editor")) {
            coordinator?.openLinkedFavorite(favorite)
        }

        Button(String(localized: "Edit Metadata...")) {
            linkedMetadataTarget = favorite
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            if let loaded = FileTextLoader.load(favorite.fileURL) {
                NSPasteboard.general.setString(loaded.content, forType: .string)
            }
        } label: {
            Label(String(localized: "Copy Query"), systemImage: "doc.on.doc")
        }

        Button(String(localized: "Show in Finder")) {
            coordinator?.revealLinkedFavoriteInFinder(favorite)
        }

        Divider()

        Button(role: .destructive) {
            linkedFileToTrash = favorite
            showTrashLinkedFileAlert = true
        } label: {
            Text(String(localized: "Move File to Trash"))
        }
    }

    @ViewBuilder
    private func linkedFolderContextMenu(_ folder: LinkedSQLFolder) -> some View {
        Button(String(localized: "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([folder.expandedURL])
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.expandedURL.path, forType: .string)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "doc.on.doc")
        }

        Divider()

        Button(folder.isEnabled
               ? String(localized: "Disable")
               : String(localized: "Enable")) {
            toggleLinkedFolder(folder)
        }

        Button(String(localized: "Reload")) {
            SQLFolderWatcher.shared.reload()
        }

        Divider()

        Button(String(localized: "Add Another SQL Folder...")) {
            addLinkedFolder()
        }

        Divider()

        Button(role: .destructive) {
            linkedFolderToRemove = folder
            showRemoveLinkedFolderAlert = true
        } label: {
            Text(String(localized: "Remove from Sidebar"))
        }
    }

    private func toggleLinkedFolder(_ folder: LinkedSQLFolder) {
        var updated = folder
        updated.isEnabled.toggle()
        LinkedSQLFolderStorage.shared.updateFolder(updated)
        SQLFolderWatcher.shared.reload()
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: SQLFavoriteFolder) -> some View {
        Button(String(localized: "Rename")) {
            viewModel.startRenameFolder(folder)
        }

        Button(String(localized: "New Favorite...")) {
            viewModel.createFavorite(folderId: folder.id)
        }

        Button(String(localized: "New Subfolder")) {
            viewModel.createFolder(parentId: folder.id)
        }

        Divider()

        Button(role: .destructive) {
            folderToDelete = folder
            showDeleteFolderAlert = true
        } label: {
            Text(String(localized: "Delete Folder"))
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Favorites"), systemImage: "star")
        } description: {
            Text("Save frequently used queries, or link a folder of .sql files to share with your team.")
        } actions: {
            Button(String(localized: "Link a Folder...")) {
                addLinkedFolder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button(String(localized: "New Favorite")) {
                    viewModel.createFavorite()
                }
                Button(String(localized: "New Folder")) {
                    viewModel.createFolder()
                }
                Divider()
                Button(String(localized: "Add Linked SQL Folder...")) {
                    addLinkedFolder()
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Add"))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func addLinkedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder containing .sql files")

        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let path = PathPortability.contractHome(url.path)
            let existing = LinkedSQLFolderStorage.shared.loadFolders()
            guard !existing.contains(where: { $0.path == path }) else { return }
            LinkedSQLFolderStorage.shared.addFolder(LinkedSQLFolder(path: path))
            SQLFolderWatcher.shared.reload()
        }
    }
}

private struct FavoriteNodeRow: View {
    let node: FavoriteNode
    let connectionId: UUID
    let viewModel: FavoritesSidebarViewModel
    @FocusState.Binding var isRenameFocused: Bool

    var body: some View {
        switch node.content {
        case .favorite(let favorite):
            FavoriteRowView(favorite: favorite)
                .tag(FavoriteSelection.node(id: node.id))
        case .folder(let folder):
            DisclosureGroup(isExpanded: folderExpansion(folder)) {
                childRows
            } label: {
                folderLabel(folder)
            }
            .tag(FavoriteSelection.node(id: node.id))
        case .linkedFolder(let linkedFolder):
            DisclosureGroup(isExpanded: linkedExpansion) {
                childRows
            } label: {
                LinkedFolderRowLabel(folder: linkedFolder)
            }
            .tag(FavoriteSelection.node(id: node.id))
        case .linkedSubfolder(_, let displayName, _):
            DisclosureGroup(isExpanded: linkedExpansion) {
                childRows
            } label: {
                LinkedSubfolderRowLabel(displayName: displayName)
            }
            .tag(FavoriteSelection.node(id: node.id))
        case .linkedFavorite(let linked):
            LinkedFavoriteRowView(favorite: linked)
                .tag(FavoriteSelection.node(id: node.id))
        }
    }

    @ViewBuilder
    private var childRows: some View {
        if let children = node.children {
            ForEach(children) { child in
                FavoriteNodeRow(
                    node: child,
                    connectionId: connectionId,
                    viewModel: viewModel,
                    isRenameFocused: $isRenameFocused
                )
            }
        }
    }

    private func folderExpansion(_ folder: SQLFavoriteFolder) -> Binding<Bool> {
        Binding(
            get: { FavoritesExpansionState.shared.isFolderExpanded(folder.id, for: connectionId) },
            set: { FavoritesExpansionState.shared.setFolderExpanded(folder.id, expanded: $0, for: connectionId) }
        )
    }

    private var linkedExpansion: Binding<Bool> {
        Binding(
            get: { FavoritesExpansionState.shared.isLinkedNodeExpanded(node.id, for: connectionId) },
            set: { FavoritesExpansionState.shared.setLinkedNodeExpanded(node.id, expanded: $0, for: connectionId) }
        )
    }

    @ViewBuilder
    private func folderLabel(_ folder: SQLFavoriteFolder) -> some View {
        if viewModel.renamingFolderId == folder.id {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                TextField(
                    "",
                    text: Binding(
                        get: { viewModel.renamingFolderName },
                        set: { viewModel.renamingFolderName = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "Folder name"))
                .focused($isRenameFocused)
                .onSubmit { viewModel.commitRenameFolder(folder) }
                .onExitCommand { viewModel.renamingFolderId = nil }
                .onAppear { isRenameFocused = true }
            }
        } else {
            Label(folder.name, systemImage: "folder")
        }
    }
}
