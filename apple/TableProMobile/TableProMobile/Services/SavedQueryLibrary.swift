import Foundation
import Observation
import os
import TableProImport
import TableProModels

@MainActor @Observable
final class SavedQueryLibrary {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SavedQueryLibrary")

    private var state: Loadable<SavedQueryContents> = .loading

    var status: LoadStatus { state.status }
    var contents: SavedQueryContents { state.value ?? SavedQueryContents() }

    // Nil while the file is not loaded, so sync never merges into or pushes from an empty stand-in.
    var syncContents: SavedQueryContents? { state.value }

    // Whether records owned by this connection leave the device; the sample's never do.
    @ObservationIgnored var syncsOwner: (UUID) -> Bool = { _ in true }

    @ObservationIgnored private let persistence: SavedQueryPersistence
    @ObservationIgnored private let syncCoordinator: IOSSyncCoordinator
    @ObservationIgnored private var deferredPurges: [SavedQueryPurge] = []

    init(directory: URL, syncCoordinator: IOSSyncCoordinator) {
        persistence = SavedQueryPersistence(directory: directory)
        self.syncCoordinator = syncCoordinator
        do {
            deferredPurges = try persistence.loadPurges()
        } catch {
            Self.logger.error("Deferred saved query purges failed to load: \(error.localizedDescription, privacy: .public)")
        }
        load()
    }

    var importStore: IOSSavedQueryImportStore {
        IOSSavedQueryImportStore(library: self)
    }

    func contents(visibleTo connectionId: UUID) -> SavedQueryContents {
        contents.visible(to: connectionId)
    }

    // MARK: - Load

    func retryLoadIfFailed() {
        guard status == .failed else { return }
        Self.logger.info("Retrying the saved queries load after a failure")
        load()
    }

    private func load() {
        do {
            state = .loaded(try persistence.load())
        } catch {
            state = .failed(error)
            Self.logger.error("Saved queries load failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        runDeferredPurges()
    }

    // MARK: - Queries

    @discardableResult
    func insert(_ query: SavedQuery) -> Bool {
        guard var updated = writableContents(), updated.query(query.id) == nil else { return false }
        updated.queries.append(query)
        guard commit(updated) else { return false }
        markDirty(queries: [query])
        return true
    }

    // The edit runs on the stored row, so a change a pull made while a form was open survives the save.
    @discardableResult
    func update(_ id: UUID, _ edit: (inout SavedQuery) -> Void) -> Bool {
        guard var updated = writableContents(),
              let index = updated.queries.firstIndex(where: { $0.id == id }) else { return false }
        let before = updated.queries[index]
        var query = before
        edit(&query)
        guard query != before else { return true }
        query.updatedAt = Date()
        updated.queries[index] = query
        guard commit(updated) else { return false }
        markDirty(queries: [query])
        return true
    }

    @discardableResult
    func deleteQuery(_ id: UUID) -> Bool {
        guard var updated = writableContents(),
              let index = updated.queries.firstIndex(where: { $0.id == id }) else { return false }
        let removed = updated.queries.remove(at: index)
        guard commit(updated) else { return false }
        markDeleted(queries: [removed])
        return true
    }

    func isKeywordAvailable(_ keyword: String, connectionId: UUID?, excluding excludedId: UUID? = nil) -> Bool {
        guard let keyword = SavedQueryKeyword.normalized(keyword) else { return true }
        let holderScopes = contents.queries
            .filter { $0.id != excludedId && $0.keyword == keyword }
            .map(\.connectionId)
        return SavedQueryKeyword.isAvailable(keyword, scope: connectionId, holderScopes: holderScopes)
    }

    // MARK: - Folders

    @discardableResult
    func insertFolder(_ folder: SavedQueryFolder) -> Bool {
        guard var updated = writableContents(), updated.folder(folder.id) == nil else { return false }
        if let parentId = folder.parentId, updated.isFolder(parentId, insideOrEqualTo: folder.id) { return false }
        updated.folders.append(folder)
        guard commit(updated) else { return false }
        markDirty(folders: [folder])
        return true
    }

    @discardableResult
    func updateFolder(_ id: UUID, _ edit: (inout SavedQueryFolder) -> Void) -> Bool {
        guard var updated = writableContents(),
              let index = updated.folders.firstIndex(where: { $0.id == id }) else { return false }
        let before = updated.folders[index]
        var folder = before
        edit(&folder)
        guard folder != before else { return true }
        if let parentId = folder.parentId, updated.isFolder(parentId, insideOrEqualTo: id) { return false }
        folder.updatedAt = Date()
        updated.folders[index] = folder
        guard commit(updated) else { return false }
        markDirty(folders: [folder])
        return true
    }

    @discardableResult
    func deleteFolder(_ id: UUID) -> Bool {
        guard var updated = writableContents() else { return false }
        guard let deletion = updated.removeFolder(id) else { return false }
        guard commit(updated) else { return false }
        markDeleted(folders: [deletion.removed])
        markDirty(queries: deletion.moved.queries, folders: deletion.moved.folders)
        return true
    }

    // MARK: - Connections

    // A purge that cannot be written now is kept on disk and runs once the saved queries load and write again.
    func removeRecords(ofConnections connectionIds: Set<UUID>, tombstoning: Bool) {
        guard !connectionIds.isEmpty else { return }
        let pending = deferredPurges + [SavedQueryPurge(connectionIds: connectionIds, tombstoning: tombstoning)]
        deferPurges(purge(pending) ? [] : pending)
    }

    private func purge(_ purges: [SavedQueryPurge]) -> Bool {
        guard var updated = writableContents() else { return false }
        var deleted = SavedQueryContents()
        var detachedIds: (queries: Set<UUID>, folders: Set<UUID>) = ([], [])
        for purge in purges {
            let change = updated.removeRecords(scopedTo: purge.connectionIds)
            guard purge.tombstoning else { continue }
            deleted.queries += change.removed.queries
            deleted.folders += change.removed.folders
            detachedIds.queries.formUnion(change.detached.queries.map(\.id))
            detachedIds.folders.formUnion(change.detached.folders.map(\.id))
        }
        guard updated != state.value else { return true }
        guard write(updated) else { return false }
        markDeleted(queries: deleted.queries, folders: deleted.folders)
        markDirty(
            queries: updated.queries.filter { detachedIds.queries.contains($0.id) },
            folders: updated.folders.filter { detachedIds.folders.contains($0.id) }
        )
        return true
    }

    private func runDeferredPurges() {
        guard !deferredPurges.isEmpty, purge(deferredPurges) else { return }
        deferPurges([])
    }

    private func deferPurges(_ purges: [SavedQueryPurge]) {
        guard purges != deferredPurges else { return }
        deferredPurges = purges
        do {
            try persistence.savePurges(purges)
        } catch {
            Self.logger.error("Failed to save deferred saved query purges: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Import

    func ledgerEntries() -> [SavedQueryLedger.Entry]? {
        state.value?.queries.map(\.ledgerEntry)
    }

    func importSavedQueries(_ planned: [PlannedQuery], now: Date = Date()) -> SavedQueryImportWrite? {
        guard var updated = writableContents() else { return nil }
        let write = updated.importing(planned, now: now)
        guard !write.insertedIds.isEmpty || !write.createdFolderIds.isEmpty else { return write }
        guard commit(updated) else { return nil }
        let inserted = Set(write.insertedIds)
        let created = Set(write.createdFolderIds)
        markDirty(
            queries: updated.queries.filter { inserted.contains($0.id) },
            folders: updated.folders.filter { created.contains($0.id) }
        )
        return write
    }

    // MARK: - Sync

    func applySynced(_ merged: SavedQueryContents) -> Bool {
        guard let current = state.value else { return false }
        guard merged != current else { return true }
        return commit(merged)
    }

    // MARK: - Writing

    private func writableContents() -> SavedQueryContents? {
        guard let current = state.value else {
            Self.logger.error("Refusing a saved query write while the stored saved queries are not loaded")
            return nil
        }
        return current
    }

    // A purge a failed write deferred runs on the next write that lands.
    private func commit(_ updated: SavedQueryContents) -> Bool {
        guard write(updated) else { return false }
        runDeferredPurges()
        return true
    }

    private func write(_ updated: SavedQueryContents) -> Bool {
        do {
            try persistence.save(updated)
        } catch {
            Self.logger.error("Failed to save saved queries: \(error.localizedDescription, privacy: .public)")
            return false
        }
        state = .loaded(updated)
        return true
    }

    // MARK: - Sync Marks

    private func syncs(_ owner: UUID?) -> Bool {
        owner.map(syncsOwner) ?? true
    }

    // A record moved to a connection that never syncs is held, as on the Mac: its iCloud copy stays as it was.
    private func markDirty(queries: [SavedQuery] = [], folders: [SavedQueryFolder] = []) {
        let queryIds = queries.filter { syncs($0.connectionId) }.map(\.id)
        let folderIds = folders.filter { syncs($0.connectionId) }.map(\.id)
        guard !queryIds.isEmpty || !folderIds.isEmpty else { return }
        syncCoordinator.markDirty(savedQueries: queryIds, folders: folderIds)
        syncCoordinator.scheduleSyncAfterChange()
    }

    private func markDeleted(queries: [SavedQuery] = [], folders: [SavedQueryFolder] = []) {
        let queryIds = queries.filter { syncs($0.connectionId) }.map(\.id)
        let folderIds = folders.filter { syncs($0.connectionId) }.map(\.id)
        guard !queryIds.isEmpty || !folderIds.isEmpty else { return }
        syncCoordinator.markDeleted(savedQueries: queryIds, folders: folderIds)
        syncCoordinator.scheduleSyncAfterChange()
    }
}
