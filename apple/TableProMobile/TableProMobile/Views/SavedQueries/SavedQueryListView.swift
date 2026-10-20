import SwiftUI
import TableProConnectionLibrary
import TableProModels

// Routes carry the row as the user saw it, so a form stays open when a pull deletes the record.
enum SavedQueryListRoute: Hashable {
    case edit(SavedQuery)
    case move(SavedQuery)
    case newFolder(parentId: UUID?)
    case renameFolder(SavedQueryFolder)
}

struct SavedQueryListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let connectionId: UUID
    @Binding var expandedFolderIds: Set<UUID>
    let onOpen: (String) -> Void

    @State private var searchText = ""
    @State private var route: SavedQueryListRoute?
    @State private var renamingQueryId: UUID?
    @State private var queryPendingDeletion: SavedQuery?
    @State private var folderPendingDeletion: SavedQueryFolder?
    @State private var failure: SavedQueryWriteFailure?

    var body: some View {
        let visible = appState.savedQueries.contents(visibleTo: connectionId)
        let outline = SavedQueryOutline.build(folders: visible.folders, queries: visible.queries)
        let shown = SavedQueryOutline.filter(outline, matching: searchText)
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFolders = !visible.folders.isEmpty
        List {
            SavedQueryTreeLevel(
                nodes: shown,
                isExpanded: { folderExpansion($0, isSearching: isSearching) },
                queryRow: { queryRow($0, canMove: hasFolders || $0.folderId != nil) },
                folderLabel: { folderRow($0) }
            )
        }
        .listStyle(.insetGrouped)
        .overlay {
            if outline.isEmpty {
                ContentUnavailableView(
                    "No Saved Queries",
                    systemImage: "star",
                    description: Text("Queries you save from the Query menu appear here.")
                )
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: Text("Search Saved Queries"))
        .navigationTitle("Saved Queries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    route = .newFolder(parentId: nil)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                CloseButton { dismiss() }
            }
        }
        .navigationDestination(item: $route) { destination($0) }
        .confirmationDialog(
            String(localized: "Delete Saved Query?"),
            isPresented: queryDeletionPresented,
            titleVisibility: .visible,
            presenting: queryPendingDeletion
        ) { query in
            Button(String(localized: "Delete"), role: .destructive) {
                delete(query)
            }
        } message: { query in
            Text(String(format: String(localized: "\"%@\" will be permanently deleted."), query.name))
        }
        .confirmationDialog(
            String(localized: "Delete Folder?"),
            isPresented: folderDeletionPresented,
            titleVisibility: .visible,
            presenting: folderPendingDeletion
        ) { folder in
            Button(String(localized: "Delete"), role: .destructive) {
                delete(folder)
            }
        } message: { folder in
            Text(String(
                format: String(localized: "The folder \"%@\" will be deleted. Items inside will be moved to the parent level."),
                folder.name
            ))
        }
        .savedQueryWriteFailureAlert($failure)
    }

    // MARK: - Rows

    private func queryRow(_ query: SavedQuery, canMove: Bool) -> some View {
        SavedQueryRow(
            query: query,
            isRenaming: renamingQueryId == query.id,
            onOpen: { onOpen(query.query) },
            onCommitRename: { commitRename(query, to: $0) },
            onCancelRename: { renamingQueryId = nil }
        )
        .swipeActions(edge: .leading) {
            Button {
                route = .edit(query)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                queryPendingDeletion = query
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            queryMenu(query, canMove: canMove)
        }
        .renameAction {
            renamingQueryId = query.id
        }
        .accessibilityAction(named: Text("Delete")) {
            queryPendingDeletion = query
        }
    }

    @ViewBuilder
    private func queryMenu(_ query: SavedQuery, canMove: Bool) -> some View {
        Button {
            onOpen(query.query)
        } label: {
            Label("Open in Editor", systemImage: "arrow.right.circle")
        }
        Button {
            ClipboardExporter.copyToClipboard(query.query)
        } label: {
            Label("Copy Query", systemImage: "doc.on.doc")
        }
        Divider()
        RenameButton()
        Button {
            route = .edit(query)
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        if canMove {
            Button {
                route = .move(query)
            } label: {
                Label("Move to Folder…", systemImage: "folder")
            }
        }
        Divider()
        Button(role: .destructive) {
            queryPendingDeletion = query
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func folderRow(_ folder: SavedQueryFolder) -> some View {
        SavedQueryFolderLabel(folder: folder)
            .contentShape(Rectangle())
            .swipeActions(edge: .leading) {
                Button {
                    route = .renameFolder(folder)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    folderPendingDeletion = folder
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .contextMenu {
                folderMenu(folder)
            }
            .renameAction {
                route = .renameFolder(folder)
            }
            .accessibilityAction(named: Text("Delete Folder")) {
                folderPendingDeletion = folder
            }
    }

    @ViewBuilder
    private func folderMenu(_ folder: SavedQueryFolder) -> some View {
        Button {
            route = .newFolder(parentId: folder.id)
        } label: {
            Label("New Subfolder", systemImage: "folder.badge.plus")
        }
        Divider()
        RenameButton()
        Toggle(isOn: Binding(
            get: { folder.connectionId == nil },
            set: { setGlobal(folder, $0) }
        )) {
            Label("Global", systemImage: "globe")
        }
        Divider()
        Button(role: .destructive) {
            folderPendingDeletion = folder
        } label: {
            Label("Delete Folder", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func destination(_ target: SavedQueryListRoute) -> some View {
        switch target {
        case .edit(let query):
            SavedQueryFormView(editing: query, connectionId: connectionId)
        case .move(let query):
            SavedQueryFolderPicker(
                folders: appState.savedQueries.contents(visibleTo: connectionId).folders,
                selection: query.folderId,
                recordScope: query.connectionId,
                title: String(localized: "Move to Folder")
            ) { move(query, to: $0) }
        case .newFolder(let parentId):
            SavedQueryFolderNameForm(mode: .create(parentId: parentId), connectionId: connectionId) { _ in
                if let parentId {
                    expandedFolderIds.insert(parentId)
                }
            }
        case .renameFolder(let folder):
            SavedQueryFolderNameForm(mode: .rename(folder), connectionId: connectionId)
        }
    }

    // MARK: - Edits

    private func commitRename(_ query: SavedQuery, to proposed: String) {
        guard renamingQueryId == query.id else { return }
        renamingQueryId = nil
        guard let name = SavedQueryDraft.renamedName(proposed, of: query) else { return }
        let store = appState.savedQueries
        let renamed = store.update(query.id) { $0.name = name }
        if !renamed {
            failure = .failedQueryWrite(query.id, in: store.contents.queries)
        }
    }

    private func move(_ query: SavedQuery, to folderId: UUID?) {
        guard folderId != query.folderId else { return }
        let store = appState.savedQueries
        let folder = folderId.flatMap { store.contents.folder($0) }
        guard folderId == nil || folder != nil else {
            failure = .folderDeleted
            return
        }
        let moved = store.update(query.id) { SavedQueryDraft.move(&$0, to: folder) }
        if !moved {
            failure = .failedQueryWrite(query.id, in: store.contents.queries)
        }
    }

    private func setGlobal(_ folder: SavedQueryFolder, _ isGlobal: Bool) {
        let store = appState.savedQueries
        let scope = isGlobal ? nil : connectionId
        let updated = store.updateFolder(folder.id) { $0.connectionId = scope }
        if !updated {
            failure = .failedFolderWrite(folder.id, in: store.contents.folders)
        }
    }

    private func delete(_ query: SavedQuery) {
        let store = appState.savedQueries
        if !store.deleteQuery(query.id) {
            failure = .failedQueryWrite(query.id, in: store.contents.queries)
        }
    }

    private func delete(_ folder: SavedQueryFolder) {
        let store = appState.savedQueries
        if !store.deleteFolder(folder.id) {
            failure = .failedFolderWrite(folder.id, in: store.contents.folders)
        }
    }

    // MARK: - Bindings

    // Folders holding a match open while a search runs, the way the connection list opens its groups.
    private func folderExpansion(_ folderId: UUID, isSearching: Bool) -> Binding<Bool> {
        Binding(
            get: { isSearching || expandedFolderIds.contains(folderId) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderIds.insert(folderId)
                } else {
                    expandedFolderIds.remove(folderId)
                }
            }
        )
    }

    private var queryDeletionPresented: Binding<Bool> {
        Binding(
            get: { queryPendingDeletion != nil },
            set: { if !$0 { queryPendingDeletion = nil } }
        )
    }

    private var folderDeletionPresented: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )
    }
}

private struct SavedQueryTreeLevel<QueryRow: View, FolderLabel: View>: View {
    let nodes: [SavedQueryOutlineNode<SavedQueryFolder, SavedQuery>]
    let isExpanded: (UUID) -> Binding<Bool>
    let queryRow: (SavedQuery) -> QueryRow
    let folderLabel: (SavedQueryFolder) -> FolderLabel

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .folder(let folder, let children):
                DisclosureGroup(isExpanded: isExpanded(folder.id)) {
                    SavedQueryTreeLevel(
                        nodes: children,
                        isExpanded: isExpanded,
                        queryRow: queryRow,
                        folderLabel: folderLabel
                    )
                } label: {
                    folderLabel(folder)
                }
            case .query(let query):
                queryRow(query)
            }
        }
    }
}
