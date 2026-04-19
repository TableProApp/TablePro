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
    @State private var selectedNodeId: String?
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
            let items = viewModel.filteredNodes(searchText: searchText)

            if viewModel.isLoading && viewModel.nodes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.nodes.isEmpty && searchText.isEmpty {
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

    private func favoritesList(_ items: [FavoriteNode]) -> some View {
        List(selection: $selectedNodeId) {
            nodeRows(items)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            deleteSelectedFavorite()
        }
        .onKeyPress(.return) {
            guard viewModel.renamingFolderId == nil,
                  let nodeId = selectedNodeId,
                  let fav = viewModel.favoriteForNodeId(nodeId) else { return .ignored }
            coordinator?.insertFavorite(fav)
            return .handled
        }
    }

    private func nodeRows(_ items: [FavoriteNode]) -> AnyView {
        AnyView(ForEach(items) { node in
            switch node.content {
            case .favorite(let favorite):
                FavoriteRowView(favorite: favorite)
                    .tag(node.id)
                    .contextMenu {
                        favoriteContextMenu(favorite)
                    }
            case .folder(let folder):
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
                    if let children = node.children {
                        nodeRows(children)
                    }
                } label: {
                    folderLabel(folder)
                }
            }
        })
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
                    folderContextMenu(folder)
                }
        }
    }

    private func deleteSelectedFavorite() {
        guard let nodeId = selectedNodeId,
              let fav = viewModel.favoriteForNodeId(nodeId) else { return }
        viewModel.deleteFavorite(fav)
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
            Text(String(localized: "Delete"))
        }
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
        ContentUnavailableView(
            String(localized: "No Favorites"),
            systemImage: "star",
            description: Text("Save frequently used queries for quick access.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        ContentUnavailableView(
            String(localized: "No Matching Favorites"),
            systemImage: "magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.createFavorite()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "New Favorite"))

            Spacer()

            Button {
                viewModel.createFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "New Folder"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
