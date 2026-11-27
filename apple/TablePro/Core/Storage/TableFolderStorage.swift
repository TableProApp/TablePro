//
//  TableFolderStorage.swift
//  TablePro
//

import Foundation
import os
import TableProSyncTransport

extension Notification.Name {
    static let tableFoldersDidChange = Notification.Name("TableFoldersDidChange")
}

// A folder only records which objects it holds, so nothing here ever reaches the database.
@MainActor
internal final class TableFolderStorage: TableScopedSettingsStore {
    static let shared = TableFolderStorage(core: .shared)
    nonisolated static let connectionIdUserInfoKey = "connectionId"

    private static let logger = Logger(subsystem: "com.TablePro", category: "TableFolderStorage")

    struct Document: Codable, Equatable {
        var folders: [TableFolder] = []
        var items: [TableFolderItem] = []

        var isEmpty: Bool { folders.isEmpty && items.isEmpty }
    }

    // Deletions are marked first, so an id an edit both removed and wrote back ends up saved, not deleted.
    private struct SyncMarks {
        var dirtyFolders: [String] = []
        var deletedFolders: [String] = []
        var dirtyItems: [String] = []
        var deletedItems: [String] = []

        var isEmpty: Bool {
            dirtyFolders.isEmpty && deletedFolders.isEmpty && dirtyItems.isEmpty && deletedItems.isEmpty
        }
    }

    private let store: KeyValueStore
    private let syncTracker: SyncChangeTracker
    private let notificationCenter: NotificationCenter
    private var documents: [UUID: Document] = [:]
    // Read as empty and never written, so a damaged or newer document is not replaced by the next edit.
    private var unreadableConnectionIds: Set<UUID> = []
    // Nil keeps the folders out of the core, for a store nothing else reads.
    private(set) var coreMirror: CoreMirror<TableFolderCoreAdapter>?

    init(
        defaults: KeyValueStore = AppStorageEnvironment.shared.defaults,
        syncTracker: SyncChangeTracker = .shared,
        notificationCenter: NotificationCenter = .default,
        core: CoreHistoryDatabase? = nil,
        mirrorDefaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        self.store = defaults
        self.syncTracker = syncTracker
        self.notificationCenter = notificationCenter
        if let core {
            coreMirror = CoreMirror(adapter: TableFolderCoreAdapter(store: self, database: core), defaults: mirrorDefaults)
        }
    }

    // MARK: - Reading

    func layout(in scope: DatabaseScope) -> TableFolderLayout {
        let document = document(for: scope.connectionId)
        let folders = document.folders
            .filter { $0.scope == scope }
            .sorted(by: Self.precedes)
        let folderIds = Set(folders.map(\.id))
        var placements: [String: UUID] = [:]
        for item in document.items where item.scope == scope && folderIds.contains(item.folderId) {
            placements[item.name] = item.folderId
        }
        return TableFolderLayout(folders: folders, placements: placements)
    }

    func folder(id: UUID, connectionId: UUID) -> TableFolder? {
        document(for: connectionId).folders.first { $0.id == id }
    }

    var hasUnreadableDocuments: Bool {
        !unreadableConnectionIds.isEmpty
    }

    func allFolders() -> [TableFolder] {
        storedConnectionIds().flatMap { document(for: $0).folders }
    }

    func allItems() -> [TableFolderItem] {
        storedConnectionIds().flatMap { document(for: $0).items }
    }

    // Ignores case, because two folders a Move to menu cannot tell apart are no help.
    func availableFolderName(in scope: DatabaseScope) -> String {
        let taken = Set(layout(in: scope).folders.map { $0.name.lowercased() })
        let base = String(localized: "New Folder")
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains(Self.numberedName(number).lowercased()) {
            number += 1
        }
        return Self.numberedName(number)
    }

    private static func numberedName(_ number: Int) -> String {
        String(format: String(localized: "New Folder %lld"), number)
    }

    // MARK: - Editing

    @discardableResult
    func createFolder(
        id: UUID = UUID(),
        named name: String,
        in scope: DatabaseScope,
        containing names: [String] = []
    ) -> TableFolder {
        let folder = TableFolder(id: id, scope: scope, name: name)
        var document = document(for: scope.connectionId)
        document.folders.append(folder)
        let filed = Self.file(names, in: scope, into: folder.id, document: &document)
        commit(document, for: scope.connectionId, marks: SyncMarks(
            dirtyFolders: [folder.id.uuidString],
            dirtyItems: filed.map(\.syncId)
        ))
        return folder
    }

    func renameFolder(id: UUID, connectionId: UUID, to name: String) {
        var document = document(for: connectionId)
        guard let index = document.folders.firstIndex(where: { $0.id == id }),
              document.folders[index].name != name else { return }
        document.folders[index].name = name
        document.folders[index].updatedAt = Date()
        commit(document, for: connectionId, marks: SyncMarks(dirtyFolders: [id.uuidString]))
    }

    func deleteFolder(id: UUID, connectionId: UUID) {
        var document = document(for: connectionId)
        guard !document.folders.extract(where: { $0.id == id }).isEmpty else { return }
        let released = document.items.extract { $0.folderId == id }
        commit(document, for: connectionId, marks: SyncMarks(
            deletedFolders: [id.uuidString],
            deletedItems: released.map(\.syncId)
        ))
    }

    func fileObjects(_ names: [String], in scope: DatabaseScope, into folderId: UUID) {
        var document = document(for: scope.connectionId)
        guard document.folders.contains(where: { $0.id == folderId && $0.scope == scope }) else { return }
        let filed = Self.file(names, in: scope, into: folderId, document: &document)
        guard !filed.isEmpty else { return }
        commit(document, for: scope.connectionId, marks: SyncMarks(dirtyItems: filed.map(\.syncId)))
    }

    func unfileObjects(_ names: [String], in scope: DatabaseScope) {
        let keys = Set(names.map { TableFolderItemKey(scope: scope, name: $0) })
        var document = document(for: scope.connectionId)
        let released = document.items.extract { keys.contains($0.key) }
        guard !released.isEmpty else { return }
        commit(document, for: scope.connectionId, marks: SyncMarks(deletedItems: released.map(\.syncId)))
    }

    private static func file(
        _ names: [String],
        in scope: DatabaseScope,
        into folderId: UUID,
        document: inout Document
    ) -> [TableFolderItem] {
        var indexByKey = Dictionary(
            document.items.enumerated().map { ($1.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var filed: [TableFolderItem] = []
        for name in Set(names) {
            let item = TableFolderItem(scope: scope, name: name, folderId: folderId)
            if let index = indexByKey[item.key] {
                guard document.items[index].folderId != folderId else { continue }
                document.items[index] = item
            } else {
                indexByKey[item.key] = document.items.count
                document.items.append(item)
            }
            filed.append(item)
        }
        return filed
    }

    // MARK: - Undo

    // Only these entries are restored, so a rename from another window or a pull from another Mac in between survives.
    func capture(folderIds: Set<UUID>, itemKeys: Set<TableFolderItemKey>, connectionId: UUID) -> TableFolderRevision {
        let document = document(for: connectionId)
        var folders: [UUID: TableFolder?] = [:]
        for id in folderIds {
            folders[id] = document.folders.first { $0.id == id }
        }
        let placements = Dictionary(
            document.items.filter { itemKeys.contains($0.key) }.map { ($0.key, $0.folderId) },
            uniquingKeysWith: { first, _ in first }
        )
        var items: [TableFolderItemKey: UUID?] = [:]
        for key in itemKeys {
            items[key] = placements[key]
        }
        return TableFolderRevision(connectionId: connectionId, folders: folders, items: items)
    }

    // Returns the redo. A live folder keeps its scope, since a schema rename since the edit moved its objects with it.
    @discardableResult
    func restore(_ revision: TableFolderRevision) -> TableFolderRevision {
        let current = capture(
            folderIds: Set(revision.folders.keys),
            itemKeys: Set(revision.items.keys),
            connectionId: revision.connectionId
        )
        var document = document(for: revision.connectionId)
        var marks = SyncMarks()
        var released: [TableFolderItem] = []
        for (id, target) in revision.folders where current.folders[id] != target {
            let live = document.folders.firstIndex { $0.id == id }
            switch (live, target) {
            case (let index?, let target?):
                guard document.folders[index].name != target.name else { continue }
                document.folders[index].name = target.name
                document.folders[index].updatedAt = Date()
                marks.dirtyFolders.append(id.uuidString)
            case (nil, let target?):
                document.folders.append(target)
                marks.dirtyFolders.append(id.uuidString)
            case (let index?, nil):
                document.folders.remove(at: index)
                marks.deletedFolders.append(id.uuidString)
                released += document.items.extract { $0.folderId == id && revision.items[$0.key] == nil }
            case (nil, nil):
                continue
            }
        }
        marks.deletedItems = released.map(\.syncId)
        let changedItems = revision.items.filter { current.items[$0.key] != $0.value }
        document.items.removeAll { changedItems[$0.key] != nil }
        for (key, target) in changedItems {
            if let target {
                document.items.append(TableFolderItem(scope: key.scope, name: key.name, folderId: target))
                marks.dirtyItems.append(key.syncId)
            } else {
                marks.deletedItems.append(key.syncId)
            }
        }
        guard !marks.isEmpty, commit(document, for: revision.connectionId, marks: marks) else { return current }
        var inverseItems = current.items
        for item in released {
            inverseItems[item.key] = item.folderId
        }
        return TableFolderRevision(connectionId: revision.connectionId, folders: current.folders, items: inverseItems)
    }

    // MARK: - Remote changes

    // Marks nothing: a mark would push the change straight back to the Mac that made it.
    func applyRemote(folders: [TableFolder], items: [TableFolderItem], excluding keptLocal: Set<UUID> = []) {
        let foldersByConnection = Dictionary(grouping: folders) { $0.scope.connectionId }
        let itemsByConnection = Dictionary(grouping: items) { $0.scope.connectionId }
        var touched: [UUID: Document] = [:]
        for connectionId in Set(foldersByConnection.keys).union(itemsByConnection.keys)
        where !keptLocal.contains(connectionId) {
            var document = document(for: connectionId)
            let incomingFolders = foldersByConnection[connectionId] ?? []
            let incomingItems = itemsByConnection[connectionId] ?? []
            let folderIds = Set(incomingFolders.map(\.id))
            let itemKeys = Set(incomingItems.map(\.key))
            document.folders.removeAll { folderIds.contains($0.id) }
            document.folders += incomingFolders
            document.items.removeAll { itemKeys.contains($0.key) }
            document.items += incomingItems
            touched[connectionId] = document
        }
        commitRemote(touched)
        coreMirror?.schedulePush()
    }

    // Placements go with their folder; waiting for their own tombstones would hide the objects meanwhile.
    func removeRemote(folderIds: Set<UUID>, itemSyncIds: Set<String>, excluding keptLocal: Set<UUID> = []) {
        guard !folderIds.isEmpty || !itemSyncIds.isEmpty else { return }
        var touched: [UUID: Document] = [:]
        var discardedFolders: [String] = []
        var discardedItems: [String] = []
        for connectionId in storedConnectionIds() where !keptLocal.contains(connectionId) {
            var document = document(for: connectionId)
            let removedFolders = document.folders.extract { folderIds.contains($0.id) }
            let removedItems = document.items.extract {
                folderIds.contains($0.folderId) || itemSyncIds.contains($0.syncId)
            }
            guard !removedFolders.isEmpty || !removedItems.isEmpty else { continue }
            touched[connectionId] = document
            discardedFolders += removedFolders.map(\.id.uuidString)
            discardedItems += removedItems.map(\.syncId)
        }
        commitRemote(touched)
        coreMirror?.schedulePush()
        syncTracker.discardDirty(.tableFolder, ids: discardedFolders)
        syncTracker.discardDirty(.tableFolderItem, ids: discardedItems)
    }

    private func commitRemote(_ touched: [UUID: Document]) {
        let written = touched.filter { $0.value != document(for: $0.key) && persist($0.value, for: $0.key) }
        guard !written.isEmpty else { return }
        postChange(for: Set(written.keys))
    }

    // MARK: - The core's copy

    var hasUnreadableDocumentsAfterReadingAll: Bool {
        _ = storedConnectionIds().map(document(for:))
        return hasUnreadableDocuments
    }

    // The core's copy written back, marking nothing: it came from this Mac or a pull, never a new edit here.
    func applyCoreRecords(
        folders: [TableFolder],
        items: [TableFolderItem],
        removedFolderIds: Set<UUID>,
        removedItemKeys: Set<TableFolderItemKey>
    ) {
        let connections = Set(folders.map(\.scope.connectionId))
            .union(items.map(\.scope.connectionId))
            .union(storedConnectionIds())
        var touched: [UUID: Document] = [:]
        for connectionId in connections {
            var document = document(for: connectionId)
            let before = document
            let incomingFolders = folders.filter { $0.scope.connectionId == connectionId }
            let incomingItems = items.filter { $0.scope.connectionId == connectionId }
            let replacedFolders = Set(incomingFolders.map(\.id)).union(removedFolderIds)
            let replacedItems = Set(incomingItems.map(\.key)).union(removedItemKeys)
            document.folders.removeAll { replacedFolders.contains($0.id) }
            document.folders += incomingFolders
            document.items.removeAll { replacedItems.contains($0.key) }
            document.items += incomingItems
            if document != before {
                touched[connectionId] = document
            }
        }
        commitRemote(touched)
    }

    // MARK: - TableScopedSettingsStore

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        let oldKey = TableFolderItemKey(scope: Self.folderScope(of: oldScope), name: oldScope.table)
        let newKey = TableFolderItemKey(scope: Self.folderScope(of: newScope), name: newScope.table)
        guard oldKey != newKey else { return }
        var document = document(for: oldScope.connectionId)
        guard let moving = document.items.extract(where: { $0.key == oldKey }).first else { return }
        document.items.removeAll { $0.key == newKey }
        document.items.append(TableFolderItem(scope: newKey.scope, name: newKey.name, folderId: moving.folderId))
        commit(document, for: oldScope.connectionId, marks: SyncMarks(
            dirtyItems: [newKey.syncId],
            deletedItems: [oldKey.syncId]
        ))
    }

    // An arriving placement replaces one already there, so no two placements share a key or a CloudKit record.
    func renameContainer(
        connectionId: UUID,
        fromDatabase: String,
        fromSchema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        var document = document(for: connectionId)
        let move: (DatabaseScope) -> DatabaseScope? = {
            $0.moved(fromDatabase: fromDatabase, fromSchema: fromSchema, toDatabase: toDatabase, toSchema: toSchema)
        }
        var marks = SyncMarks()
        for index in document.folders.indices {
            guard let moved = move(document.folders[index].scope) else { continue }
            document.folders[index].scope = moved
            document.folders[index].updatedAt = Date()
            marks.dirtyFolders.append(document.folders[index].id.uuidString)
        }
        var relocated: [TableFolderItem] = []
        var staying: [TableFolderItem] = []
        for item in document.items {
            guard let moved = move(item.scope) else {
                staying.append(item)
                continue
            }
            let movedItem = TableFolderItem(scope: moved, name: item.name, folderId: item.folderId)
            relocated.append(movedItem)
            marks.deletedItems.append(item.syncId)
            marks.dirtyItems.append(movedItem.syncId)
        }
        guard !marks.isEmpty else { return }
        let arrivingKeys = Set(relocated.map(\.key))
        document.items = staying.filter { !arrivingKeys.contains($0.key) } + relocated
        commit(document, for: connectionId, marks: marks)
    }

    func dropTable(_ scope: TableScope) {
        unfileObjects([scope.table], in: Self.folderScope(of: scope))
    }

    // The folders go too, because the objects they held did.
    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        var document = document(for: connectionId)
        let doomedFolders = document.folders.extract { $0.scope.isInside(database: database, schema: schema) }
        let doomedItems = document.items.extract { $0.scope.isInside(database: database, schema: schema) }
        guard !doomedFolders.isEmpty || !doomedItems.isEmpty else { return }
        commit(document, for: connectionId, marks: SyncMarks(
            deletedFolders: doomedFolders.map(\.id.uuidString),
            deletedItems: doomedItems.map(\.syncId)
        ))
    }

    func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
        var purged: Set<UUID> = []
        for connectionId in connectionIds {
            let document = document(for: connectionId)
            guard !document.isEmpty else { continue }
            documents[connectionId] = Document()
            unreadableConnectionIds.remove(connectionId)
            store.removeValue(for: Self.key(for: connectionId))
            let folderIds = document.folders.map(\.id.uuidString)
            let itemIds = document.items.map(\.syncId)
            if leavesTombstones {
                syncTracker.markDeleted(.tableFolder, ids: folderIds, owner: connectionId)
                syncTracker.markDeleted(.tableFolderItem, ids: itemIds, owner: connectionId)
            } else {
                syncTracker.discardDirty(.tableFolder, ids: folderIds)
                syncTracker.discardDirty(.tableFolderItem, ids: itemIds)
            }
            purged.insert(connectionId)
        }
        if !purged.isEmpty {
            coreMirror?.schedulePush()
        }
        postChange(for: purged)
    }

    // `CatalogEditAdoption` always sets the database; the fallback only covers a hand-built scope.
    private static func folderScope(of scope: TableScope) -> DatabaseScope {
        DatabaseScope(connectionId: scope.connectionId, database: scope.database ?? "", schema: scope.schema)
    }

    // MARK: - Persistence

    // Persists before marking, because a sync mark can start a push that reads this store.
    @discardableResult
    private func commit(_ document: Document, for connectionId: UUID, marks: SyncMarks) -> Bool {
        guard persist(document, for: connectionId) else { return false }
        coreMirror?.schedulePush()
        syncTracker.markDeleted(.tableFolder, ids: marks.deletedFolders, owner: connectionId)
        syncTracker.markDeleted(.tableFolderItem, ids: marks.deletedItems, owner: connectionId)
        syncTracker.markDirty(.tableFolder, ids: marks.dirtyFolders)
        syncTracker.markDirty(.tableFolderItem, ids: marks.dirtyItems)
        postChange(for: [connectionId])
        return true
    }

    private func document(for connectionId: UUID) -> Document {
        if let cached = documents[connectionId] { return cached }
        let stored = store.read(Self.key(for: connectionId))
        if stored.isUnreadable {
            unreadableConnectionIds.insert(connectionId)
        }
        let loaded = stored.value ?? Document()
        documents[connectionId] = loaded
        return loaded
    }

    private func persist(_ document: Document, for connectionId: UUID) -> Bool {
        guard !unreadableConnectionIds.contains(connectionId) else {
            Self.logger.error("Left unreadable table folders for \(connectionId, privacy: .public) unchanged")
            return false
        }
        guard !document.isEmpty else {
            documents[connectionId] = document
            store.removeValue(for: Self.key(for: connectionId))
            return true
        }
        do {
            try store.write(document, to: Self.key(for: connectionId))
        } catch {
            return false
        }
        documents[connectionId] = document
        return true
    }

    private func storedConnectionIds() -> [UUID] {
        let prefix = PreferenceKeys.tableFoldersPrefix
        let stored = store.keys(withPrefix: prefix)
            .compactMap { UUID(uuidString: String($0.dropFirst(prefix.count))) }
        return Array(Set(stored).union(documents.keys))
    }

    private static func key(for connectionId: UUID) -> JSONDefaultsKey<Document> {
        PreferenceKeys.tableFolders(connectionId: connectionId)
    }

    private func postChange(for connectionIds: Set<UUID>) {
        for connectionId in connectionIds {
            notificationCenter.post(
                name: .tableFoldersDidChange,
                object: nil,
                userInfo: [Self.connectionIdUserInfoKey: connectionId]
            )
        }
    }

    private static func precedes(_ lhs: TableFolder, _ rhs: TableFolder) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// A nil value means the entry did not exist when captured.
internal struct TableFolderRevision: Equatable {
    internal let connectionId: UUID
    internal let folders: [UUID: TableFolder?]
    internal let items: [TableFolderItemKey: UUID?]
}

private extension Array {
    mutating func extract(where shouldExtract: (Element) -> Bool) -> [Element] {
        var extracted: [Element] = []
        removeAll { element in
            guard shouldExtract(element) else { return false }
            extracted.append(element)
            return true
        }
        return extracted
    }
}
