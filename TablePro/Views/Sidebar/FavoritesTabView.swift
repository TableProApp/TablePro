//
//  FavoritesTabView.swift
//  TablePro
//
//  Full-tab view for SQL favorites in the sidebar.
//

import SwiftUI

/// Full-tab favorites view with folder hierarchy and bottom toolbar
internal struct FavoritesTabView: View {
    @State private var viewModel: FavoritesSidebarViewModel
    @State private var selectedFavoriteIds: Set<String> = []
    @State private var folderToDelete: SQLFavoriteFolder?
    @State private var showDeleteFolderAlert = false
    @FocusState private var isRenameFocused: Bool
    let connectionId: UUID
    let searchText: String
    private var coordinator: MainContentCoordinator?

    init(connectionId: UUID, searchText: String, coordinator: MainContentCoordinator?) {
        self.connectionId = connectionId
        _viewModel = State(wrappedValue: FavoritesSidebarViewModel(connectionId: connectionId))
        self.searchText = searchText
        self.coordinator = coordinator
    }

    var body: some View {
        Group {
            let items = viewModel.filteredItems(searchText: searchText)

            if viewModel.treeItems.isEmpty && searchText.isEmpty && !viewModel.isLoading {
                emptyState
            } else if items.isEmpty {
                noMatchState
            } else {
                favoritesList(items)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                bottomToolbar
            }
        }
        .onAppear {
            Task { await viewModel.loadFavorites() }
        }
        .sheet(item: $viewModel.editDialogItem) { item in
            FavoriteEditDialog(
                connectionId: connectionId,
                favorite: item.favorite,
                initialQuery: item.query,
                folderId: item.folderId
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
            Text("The folder \"\(folder.name)\" will be deleted. Items inside will be moved to the parent level.")
        }
    }

    // MARK: - List

    private func favoritesList(_ items: [FavoriteTreeItem]) -> some View {
        List(selection: $selectedFavoriteIds) {
            flattenedRows(items)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            deleteSelectedFavorites()
        }
    }

    /// Renders tree items with DisclosureGroup for folders.
    /// Each favorite row gets `.tag()` so List selection works across all nesting levels.
    private func flattenedRows(_ items: [FavoriteTreeItem]) -> AnyView {
        AnyView(
            ForEach(items) { item in
                switch item {
                case .favorite(let favorite):
                    FavoriteRowView(favorite: favorite)
                        .tag("fav-\(favorite.id)")
                        .overlay {
                            DoubleClickDetector {
                                coordinator?.insertFavorite(favorite)
                            }
                        }
                        .contextMenu {
                            FavoriteItemContextMenu(
                                favorite: favorite,
                                viewModel: viewModel,
                                coordinator: coordinator
                            )
                        }
                case .folder(let folder, let children):
                    DisclosureGroup(isExpanded: Binding(
                        get: { viewModel.expandedFolderIds.contains(folder.id) },
                        set: { expanded in
                            if expanded {
                                viewModel.expandedFolderIds.insert(folder.id)
                            } else {
                                viewModel.expandedFolderIds.remove(folder.id)
                            }
                        }
                    )) {
                        flattenedRows(children)
                    } label: {
                        folderLabel(folder)
                    }
                }
            }
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
                .onSubmit {
                    viewModel.commitRenameFolder(folder)
                }
                .onExitCommand {
                    viewModel.renamingFolderId = nil
                }
                .onAppear {
                    isRenameFocused = true
                }
            }
        } else {
            Label(folder.name, systemImage: "folder")
                .contextMenu {
                    FolderContextMenu(
                        folder: folder,
                        viewModel: viewModel,
                        onDelete: { f in
                            folderToDelete = f
                            showDeleteFolderAlert = true
                        }
                    )
                }
        }
    }

    private func deleteSelectedFavorites() {
        let allFavorites = collectFavorites(from: viewModel.treeItems)
        let toDelete = allFavorites.filter { selectedFavoriteIds.contains("fav-\($0.id)") }
        guard !toDelete.isEmpty else { return }
        viewModel.deleteFavorites(toDelete)
        selectedFavoriteIds.removeAll()
    }

    private func collectFavorites(from items: [FavoriteTreeItem]) -> [SQLFavorite] {
        var result: [SQLFavorite] = []
        for item in items {
            switch item {
            case .favorite(let fav):
                result.append(fav)
            case .folder(_, let children):
                result.append(contentsOf: collectFavorites(from: children))
            }
        }
        return result
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "star")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("No Favorites")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            Text("Save frequently used queries\nfor quick access.")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)

            Button {
                viewModel.createFavorite()
            } label: {
                Label(String(localized: "New Favorite"), systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("No Matching Favorites")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.createFavorite()
            } label: {
                Label(String(localized: "New Favorite"), systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            Spacer()

            Button {
                viewModel.createFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .accessibilityLabel(String(localized: "New Folder"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Context Menus

private struct FavoriteItemContextMenu: View {
    let favorite: SQLFavorite
    let viewModel: FavoritesSidebarViewModel
    var coordinator: MainContentCoordinator?

    private var folders: [SQLFavoriteFolder] {
        collectFolders(from: viewModel.treeItems)
    }

    var body: some View {
        Button(String(localized: "Edit...")) {
            viewModel.editFavorite(favorite)
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(favorite.query, forType: .string)
        } label: {
            Label(String(localized: "Copy Query"), systemImage: "doc.on.doc")
        }

        Button {
            coordinator?.insertFavorite(favorite)
        } label: {
            Label(String(localized: "Insert in Editor"), systemImage: "text.insert")
        }

        Button {
            coordinator?.runFavoriteInNewTab(favorite)
        } label: {
            Label(String(localized: "Run in New Tab"), systemImage: "play")
        }

        if !folders.isEmpty {
            Divider()

            Menu(String(localized: "Move to")) {
                if favorite.folderId != nil {
                    Button(String(localized: "Root Level")) {
                        viewModel.moveFavorite(id: favorite.id, toFolder: nil)
                    }

                    Divider()
                }

                ForEach(folders) { folder in
                    if folder.id != favorite.folderId {
                        Button(folder.name) {
                            viewModel.moveFavorite(id: favorite.id, toFolder: folder.id)
                            viewModel.expandedFolderIds.insert(folder.id)
                        }
                    }
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            viewModel.deleteFavorite(favorite)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    private func collectFolders(from items: [FavoriteTreeItem]) -> [SQLFavoriteFolder] {
        var result: [SQLFavoriteFolder] = []
        for item in items {
            if case .folder(let folder, let children) = item {
                result.append(folder)
                result.append(contentsOf: collectFolders(from: children))
            }
        }
        return result
    }
}

private struct FolderContextMenu: View {
    let folder: SQLFavoriteFolder
    let viewModel: FavoritesSidebarViewModel
    var onDelete: (SQLFavoriteFolder) -> Void

    var body: some View {
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
            onDelete(folder)
        } label: {
            Label(String(localized: "Delete Folder"), systemImage: "trash")
        }
    }
}
