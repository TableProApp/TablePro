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

/// The folders tables and views are filed into, one document per connection.
///
/// A folder only records which objects belong to it, so nothing here ever reaches the database:
/// deleting a folder puts its objects back in their sections. Every edit goes through `commit`,
/// which persists before it marks anything for sync, because a sync mark can start a push that
/// reads this store.
@MainActor
internal final class TableFolderStorage: TableScopedSettingsStore {
    static let shared = TableFolderStorage()
    nonisolated static let connectionIdUserInfoKey = "connectionId"

    private static let logger = Logger(subsystem: "com.TablePro", category: "TableFolderStorage")

    private struct Document: Codable, Equatable {
        var folders: [TableFolder] = []
        var items: [TableFolderItem] = []

        var isEmpty: Bool { folders.isEmpty && items.isEmpty }
    }

    /// The sync marks one edit leaves. Deletions are marked first, so an id an edit both removed and
    /// wrote back ends up waiting to be saved rather than deleted.
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
    /// Connections whose stored folders did not decode. They read as empty and are never written,
    /// so a damaged or newer document is left for a fix rather than replaced by the next edit.
    private var unreadableConnectionIds: Set<UUID> = []

    init(
        defaults: KeyValueStore = AppStorageEnvironment.shared.defaults,
        syncTracker: SyncChangeTracker = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = defaults
        self.syncTracker = syncTracker
        self.notificationCenter = notificationCenter
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

    func allFolders() -> [TableFolder] {
        storedConnectionIds().flatMap { document(for: $0).folders }
    }

    func allItems() -> [TableFolderItem] {
        storedConnectionIds().flatMap { document(for: $0).items }
    }

    /// "New Folder", then "New Folder 2" and up, the way Finder numbers an untitled folder. Compared
    /// without regard to case, because two folders a Move to menu cannot tell apart are no help.
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

    /// The folder goes and its objects return to their sections.
    func deleteFolder(id: UUID, connectionId: UUID) {
        var document = document(for: connectionId)
        guard !document.folders.extract(where: { $0.id == id }).isEmpty else { return }
        let released = document.items.extract { $0.folderId == id }
        commit(document, for: connectionId, marks: SyncMarks(
            deletedFolders: [id.uuidString],
            deletedItems: released.map(\.syncId)
        ))
    }

    /// Files each object into the folder, taking it out of whichever folder held it before.
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

    /// The folders and placements an edit is about to touch, as they are now. Restoring it writes
    /// back only these entries, so anything else that changed in between, a rename from another
    /// window or a pull from another Mac, is left alone.
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

    /// Puts the captured entries back and returns what they were just before, which is the redo.
    ///
    /// A folder that still exists gets its name back and stays where it is now: a schema renamed
    /// since the edit has moved the folder and its objects together, and putting the old scope back
    /// would strand the folder away from them. Taking a folder away takes every object still filed
    /// in it too, so nothing is left pointing at a folder that is gone.
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

    /// Applies what another Mac pushed, marking nothing: a mark here would push the change straight
    /// back at the device that made it. An item may arrive before its folder does, and it waits in
    /// the store until the folder lands, because the sidebar only places items whose folder exists.
    /// A connection kept Local only here takes no folder change from anywhere else, the way the
    /// connection itself does not.
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
    }

    /// A folder deleted elsewhere takes its placements with it here too. The other Mac tombstoned
    /// them as well, so waiting for those deletions would only leave the objects hidden in between.
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
        syncTracker.discardDirty(.tableFolder, ids: discardedFolders)
        syncTracker.discardDirty(.tableFolderItem, ids: discardedItems)
    }

    private func commitRemote(_ touched: [UUID: Document]) {
        let written = touched.filter { $0.value != document(for: $0.key) && persist($0.value, for: $0.key) }
        guard !written.isEmpty else { return }
        postChange(for: Set(written.keys))
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

    /// A placement arriving in the renamed container replaces one the container already held for
    /// the same object, so no two placements ever share a key or a CloudKit record.
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

    /// The folders of a dropped database or schema go with it, because the objects they held did.
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
            store.setDataValue(nil, forKey: Self.key(for: connectionId))
            let folderIds = document.folders.map(\.id.uuidString)
            let itemIds = document.items.map(\.syncId)
            if leavesTombstones {
                syncTracker.markDeleted(.tableFolder, ids: folderIds)
                syncTracker.markDeleted(.tableFolderItem, ids: itemIds)
            } else {
                syncTracker.discardDirty(.tableFolder, ids: folderIds)
                syncTracker.discardDirty(.tableFolderItem, ids: itemIds)
            }
            purged.insert(connectionId)
        }
        postChange(for: purged)
    }

    /// `CatalogEditAdoption` builds every `TableScope` from a resolved `DatabaseScope`, so the
    /// database is always present there. The fallback only keeps a hand-built scope from crashing.
    private static func folderScope(of scope: TableScope) -> DatabaseScope {
        DatabaseScope(connectionId: scope.connectionId, database: scope.database ?? "", schema: scope.schema)
    }

    // MARK: - Persistence

    /// Persists, then marks, then notifies, and does none of it when the write did not land.
    @discardableResult
    private func commit(_ document: Document, for connectionId: UUID, marks: SyncMarks) -> Bool {
        guard persist(document, for: connectionId) else { return false }
        syncTracker.markDeleted(.tableFolder, ids: marks.deletedFolders)
        syncTracker.markDeleted(.tableFolderItem, ids: marks.deletedItems)
        syncTracker.markDirty(.tableFolder, ids: marks.dirtyFolders)
        syncTracker.markDirty(.tableFolderItem, ids: marks.dirtyItems)
        postChange(for: [connectionId])
        return true
    }

    private func document(for connectionId: UUID) -> Document {
        if let cached = documents[connectionId] { return cached }
        guard let loaded = loadDocument(for: connectionId) else {
            unreadableConnectionIds.insert(connectionId)
            documents[connectionId] = Document()
            return Document()
        }
        documents[connectionId] = loaded
        return loaded
    }

    private func loadDocument(for connectionId: UUID) -> Document? {
        guard let data = store.dataValue(forKey: Self.key(for: connectionId)) else { return Document() }
        do {
            return try JSONDecoder().decode(Document.self, from: data)
        } catch {
            Self.logger.error(
                "Failed to decode table folders for \(connectionId, privacy: .public): \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private func persist(_ document: Document, for connectionId: UUID) -> Bool {
        guard !unreadableConnectionIds.contains(connectionId) else {
            Self.logger.error("Left unreadable table folders for \(connectionId, privacy: .public) unchanged")
            return false
        }
        guard !document.isEmpty else {
            documents[connectionId] = document
            store.setDataValue(nil, forKey: Self.key(for: connectionId))
            return true
        }
        do {
            store.setDataValue(try JSONEncoder().encode(document), forKey: Self.key(for: connectionId))
            documents[connectionId] = document
            return true
        } catch {
            Self.logger.error(
                "Failed to encode table folders for \(connectionId, privacy: .public): \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    private func storedConnectionIds() -> [UUID] {
        let prefix = PreferenceKeys.tableFoldersPrefix
        let stored = store.keys(withPrefix: prefix)
            .compactMap { UUID(uuidString: String($0.dropFirst(prefix.count))) }
        return Array(Set(stored).union(documents.keys))
    }

    private static func key(for connectionId: UUID) -> String {
        PreferenceKeys.tableFolders(connectionId: connectionId).name
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

/// Some folders and placements of one connection as they stood at a moment. A nil value means the
/// entry did not exist then.
internal struct TableFolderRevision: Equatable {
    internal let connectionId: UUID
    internal let folders: [UUID: TableFolder?]
    internal let items: [TableFolderItemKey: UUID?]
}

private extension Array {
    /// Removes the elements that match and returns them, in one pass over the array.
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
