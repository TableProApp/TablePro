import Foundation
import os
import TableProFFI
import TableProLogRedaction
import TableProModels

// The saved queries in the core's store (core ADRs 0010 and 0054), with the previous stable's `saved-queries.json` kept
// in step after each write. A write names only the records it changes, and when a pass moved the store since the last
// read, each of those takes the fields the edit changed over the store's copy, so what the pass wrote stays. It reads
// the store back, since the store settles a contested name or keyword itself.
@MainActor
final class CoreSavedQueryStore {
    // What the last write that reached both sides left on each, so a launch can tell which side another build changed.
    struct MirrorRecord: Codable, Equatable {
        var core: String
        var legacy: String?
    }

    nonisolated static let mirrorRecordKey = "com.TablePro.savedQueries.mirrorRecord"
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CoreSavedQueryStore")

    private let host: MobileCoreHost
    private let legacy: SavedQueryPersistence
    private let defaults: UserDefaults
    private var store: SavedQueryStore?
    private var digest: String?
    // The connection name the core keeps beside each query as a display copy; iOS has no field for it.
    private var connectionNames: [UUID: String] = [:]

    init(host: MobileCoreHost, directory: URL, defaults: UserDefaults) {
        self.host = host
        legacy = SavedQueryPersistence(directory: directory)
        self.defaults = defaults
    }

    var mirrorRecord: MirrorRecord? {
        get {
            defaults.data(forKey: Self.mirrorRecordKey).flatMap { try? JSONDecoder().decode(MirrorRecord.self, from: $0) }
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.mirrorRecordKey)
                return
            }
            defaults.set(data, forKey: Self.mirrorRecordKey)
        }
    }

    // Throws when the store cannot be read, or the previous stable's file changed and no longer reads; nothing is
    // written then.
    func load() throws -> SavedQueryContents {
        let store = try openedStore()
        let contents = try CoreLibraryStore.blocking { try await store.contents() }
        let legacyDigest = legacy.digest()
        let record = mirrorRecord
        // The previous stable writes only its own file: a change there while the core's store stayed as this build left
        // it is that build's, and so is the whole file on the first launch of the core's store.
        let isFirstLaunch = record == nil && contents.queries.isEmpty && contents.folders.isEmpty
        let legacyChanged = record?.core == contents.digest && record?.legacy != legacyDigest
        if legacyDigest != nil, isFirstLaunch || legacyChanged {
            return try importLegacy(over: contents.digest, legacyDigest: legacyDigest, into: store)
        }
        let image = remember(contents)
        if record != MirrorRecord(core: contents.digest, legacy: legacyDigest) {
            mirror(image, coreDigest: contents.digest)
        }
        return image
    }

    // Nil while the store holds what this store last read or wrote.
    func reloadIfChanged() throws -> SavedQueryContents? {
        guard let store, digest != nil else { return nil }
        let contents = try CoreLibraryStore.blocking { try await store.contents() }
        guard contents.digest != digest else { return nil }
        let image = remember(contents)
        mirror(image, coreDigest: contents.digest)
        return image
    }

    // What the store holds once the change from `current` to `next` is written.
    func write(from current: SavedQueryContents, to next: SavedQueryContents) throws -> SavedQueryContents {
        let store = try openedStore()
        let held = Dictionary(current.queries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let heldFolders = Dictionary(current.folders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let nextIds = Set(next.queries.map(\.id))
        let nextFolderIds = Set(next.folders.map(\.id))
        var queries = next.queries.filter { held[$0.id] != $0 }
        var folders = next.folders.filter { heldFolders[$0.id] != $0 }
        let now = try CoreLibraryStore.blocking { try await store.contents() }
        if now.digest != digest {
            let moved = remember(now)
            let stored = Dictionary(moved.queries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let storedFolders = Dictionary(moved.folders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            queries = queries.map { mine in
                guard let theirs = stored[mine.id], let base = held[mine.id] else { return mine }
                return Self.rebased(mine, from: base, onto: theirs)
            }
            folders = folders.map { mine in
                guard let theirs = storedFolders[mine.id], let base = heldFolders[mine.id] else { return mine }
                return Self.rebased(mine, from: base, onto: theirs)
            }
        }
        let write = SavedQueryRecordWrite(
            queries: queries.map(record),
            folders: folders.map(Self.record),
            removedQueries: current.queries.map(\.id).filter { !nextIds.contains($0) }.map(\.uuidString),
            removedFolders: current.folders.map(\.id).filter { !nextFolderIds.contains($0) }.map(\.uuidString)
        )
        guard !write.queries.isEmpty || !write.folders.isEmpty || !write.removedQueries.isEmpty
            || !write.removedFolders.isEmpty else { return next }
        do {
            _ = try CoreLibraryStore.blocking { try await store.writeRecords(write: write) }
        } catch {
            Self.logger.error("The core refused the saved query write: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            throw error
        }
        let contents = try CoreLibraryStore.blocking { try await store.contents() }
        let image = remember(contents)
        mirror(image, coreDigest: contents.digest)
        return image
    }

    // Each field the edit changed over the store's copy; the rest stays as the pass wrote it.
    nonisolated static func rebased(_ mine: SavedQuery, from base: SavedQuery, onto theirs: SavedQuery) -> SavedQuery {
        var rebased = theirs
        if mine.name != base.name { rebased.name = mine.name }
        if mine.query != base.query { rebased.query = mine.query }
        if mine.keyword != base.keyword { rebased.keyword = mine.keyword }
        if mine.folderId != base.folderId { rebased.folderId = mine.folderId }
        if mine.connectionId != base.connectionId { rebased.connectionId = mine.connectionId }
        if mine.sortOrder != base.sortOrder { rebased.sortOrder = mine.sortOrder }
        rebased.updatedAt = max(mine.updatedAt, theirs.updatedAt)
        return rebased
    }

    nonisolated static func rebased(
        _ mine: SavedQueryFolder,
        from base: SavedQueryFolder,
        onto theirs: SavedQueryFolder
    ) -> SavedQueryFolder {
        var rebased = theirs
        if mine.name != base.name { rebased.name = mine.name }
        if mine.parentId != base.parentId { rebased.parentId = mine.parentId }
        if mine.connectionId != base.connectionId { rebased.connectionId = mine.connectionId }
        if mine.sortOrder != base.sortOrder { rebased.sortOrder = mine.sortOrder }
        rebased.updatedAt = max(mine.updatedAt, theirs.updatedAt)
        return rebased
    }

    // MARK: - The previous stable's file

    private func importLegacy(
        over coreDigest: String,
        legacyDigest: String?,
        into store: SavedQueryStore
    ) throws -> SavedQueryContents {
        let contents = try legacy.load()
        let queries = contents.queries.map(record)
        let folders = contents.folders.map(Self.record)
        _ = try CoreLibraryStore.blocking {
            try await store.replaceRecords(expectedDigest: coreDigest, queries: queries, folders: folders)
        }
        let read = try CoreLibraryStore.blocking { try await store.contents() }
        let image = remember(read)
        mirrorRecord = MirrorRecord(core: read.digest, legacy: legacyDigest)
        Self.logger.info("Read the saved queries from the previous stable's file into the core")
        return image
    }

    // A file the write did not reach is written again by the next launch, since the record still names the core's old
    // digest.
    private func mirror(_ image: SavedQueryContents, coreDigest: String) {
        do {
            try legacy.save(image)
            mirrorRecord = MirrorRecord(core: coreDigest, legacy: legacy.digest())
        } catch {
            Self.logger.error("The previous stable's saved queries file was not written: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
    }

    // MARK: - Records

    private func openedStore() throws -> SavedQueryStore {
        if let store { return store }
        let core = try host.core()
        let opened = try CoreLibraryStore.blocking { try await core.history() }.savedQueries()
        store = opened
        return opened
    }

    private func remember(_ contents: SavedQueryStoreContents) -> SavedQueryContents {
        digest = contents.digest
        var names: [UUID: String] = [:]
        var queries: [SavedQuery] = []
        for record in contents.queries {
            guard let query = Self.query(record) else {
                Self.logger.error("Left out a saved query whose id is not a UUID")
                continue
            }
            names[query.id] = record.connectionName
            queries.append(query)
        }
        connectionNames = names
        return SavedQueryContents(queries: queries, folders: contents.folders.compactMap(Self.folder))
    }

    private func record(_ query: SavedQuery) -> SavedQueryRecord {
        SavedQueryRecord(
            id: query.id.uuidString,
            name: query.name,
            sql: query.query,
            keyword: query.keyword,
            connectionId: query.connectionId?.uuidString,
            connectionName: connectionNames[query.id] ?? "",
            folderId: query.folderId?.uuidString,
            order: Int64(query.sortOrder),
            createdAtMs: Self.milliseconds(query.createdAt),
            updatedAtMs: Self.milliseconds(query.updatedAt)
        )
    }

    nonisolated private static func record(_ folder: SavedQueryFolder) -> SavedQueryFolderRecord {
        SavedQueryFolderRecord(
            id: folder.id.uuidString,
            name: folder.name,
            connectionId: folder.connectionId?.uuidString,
            parentId: folder.parentId?.uuidString,
            order: Int64(folder.sortOrder),
            createdAtMs: milliseconds(folder.createdAt),
            updatedAtMs: milliseconds(folder.updatedAt)
        )
    }

    nonisolated private static func query(_ record: SavedQueryRecord) -> SavedQuery? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return SavedQuery(
            id: id,
            name: record.name,
            query: record.sql,
            keyword: record.keyword,
            folderId: record.folderId.flatMap(UUID.init(uuidString:)),
            connectionId: record.connectionId.flatMap(UUID.init(uuidString:)),
            sortOrder: Int(clamping: record.order),
            createdAt: date(record.createdAtMs),
            updatedAt: date(record.updatedAtMs)
        )
    }

    nonisolated private static func folder(_ record: SavedQueryFolderRecord) -> SavedQueryFolder? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return SavedQueryFolder(
            id: id,
            name: record.name,
            parentId: record.parentId.flatMap(UUID.init(uuidString:)),
            connectionId: record.connectionId.flatMap(UUID.init(uuidString:)),
            sortOrder: Int(clamping: record.order),
            createdAt: date(record.createdAtMs),
            updatedAt: date(record.updatedAtMs)
        )
    }

    // The core keeps milliseconds, so a date goes in at that precision and comes back equal.
    nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    nonisolated private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
