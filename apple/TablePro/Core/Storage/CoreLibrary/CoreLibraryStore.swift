//
//  CoreLibraryStore.swift
//  TablePro
//

import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The connection library in the core's store (core ADR 0010, slices 1b and 2), read once into memory and written
// whole on every change, with the previous stable's stores kept in step after each write.
@MainActor
final class CoreLibraryStore {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CoreLibraryStore")

    let mirror: LegacyLibraryMirror
    let coreFileURL: URL

    private let host: CoreStoreHost
    private let localOnly: LocalOnlyConnections
    private let integrity: ConnectionStoreIntegrity

    private var library: ConnectionLibrary?
    private var image: LibraryImage?
    // The records as the core last held them, for the values the Mac has no field for.
    private var stored: [UUID: LibraryConnectionRecord] = [:]
    private var storedGroups: [UUID: GroupRecord] = [:]
    private var storedTags: [UUID: TagRecord] = [:]
    private var heldByCore: Set<UUID> = []
    // The digest of the file as this store last read or wrote it; the core refuses a write over any other.
    private var seenDigest: String?
    // False while no integrity key can be had: a store rebuilt then could not be tagged either.
    private var integrityKeyAnswered = true

    private(set) var lastLoadFailed = false
    // False until a load answers, so nothing reads "trusted" for a store nobody verified.
    private(set) var isTrusted = false
    private(set) var readCount = 0
    private(set) var writeCount = 0
    // Moves on every read and write, so a store derived from the library knows when to look again.
    var revision: Int { readCount + writeCount }

    init(
        legacyFileURL: URL,
        defaults: UserDefaults,
        keychain: any KeychainStoring,
        integrity: ConnectionStoreIntegrity
    ) {
        let folder = legacyFileURL.deletingLastPathComponent().appendingPathComponent("Core", isDirectory: true)
        coreFileURL = folder.appendingPathComponent("connections.json")
        mirror = LegacyLibraryMirror(fileURL: legacyFileURL, defaults: defaults, integrity: integrity, logger: Self.logger)
        self.integrity = integrity
        let opened = Self.coreHost(over: folder, keychain: keychain)
        host = opened.host
        localOnly = opened.localOnly
    }

    // The app's library opens on the core every store over `TablePro/Core` shares, so no second runtime holds its files;
    // a library anywhere else gets a core of its own.
    private static func coreHost(
        over folder: URL,
        keychain: any KeychainStoring
    ) -> (host: CoreStoreHost, localOnly: LocalOnlyConnections) {
        if folder.standardizedFileURL == CoreStoreHost.shared.folder.standardizedFileURL {
            return (.shared, .shared)
        }
        let localOnly = LocalOnlyConnections()
        let host = CoreStoreHost(folder: folder) {
            CoreStoreSecrets(
                items: nil,
                connections: ConnectionKeychainSecrets(keychain: keychain) { id in localOnly.contains(id) }
            )
        }
        return (host, localOnly)
    }

    // Records this build cannot read, in the core's store or in connections.json; what belongs to them is kept.
    var unreadableIds: Set<UUID> {
        heldByCore.union(mirror.unreadableIds)
    }

    // Nil when the library could not be read; nothing is written over it then.
    func current() -> LibraryImage? {
        if let image { return image }
        return load()
    }

    func invalidate() {
        image = nil
        lastLoadFailed = false
    }

    // The core's engine writes the library itself and tells this store nothing. After its pass the file is read again
    // when its digest moved, and a store this Mac vouched for is tagged again over what the core wrote.
    @discardableResult
    func readCoreWrites() -> Bool {
        guard image != nil, !lastLoadFailed, let library else { return false }
        let contents: LibraryContents
        do {
            contents = try Self.blocking { try await library.libraryContents() }
        } catch {
            Self.logger.error("The core could not read the library after a sync pass: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
        guard let digest = contents.digest, digest != seenDigest else { return false }
        let vouched = isTrusted
        let verdict: ConnectionStoreIntegrity.Verdict
        if vouched {
            verdict = .trusted
        } else {
            verdict = integrityKeyAnswered ? .modified : .unavailable
        }
        readCount += 1
        let loaded = adopt(contents, verdict: verdict)
        if vouched {
            settleTag(digest, stamping: true)
        }
        mirrorWrite(loaded, coreDigest: digest, byUser: false, removingSecrets: false, removingUnreadable: [])
        return true
    }

    // False when the core did not take the write; nothing else is written then. `byUser` true is a person's save of
    // their connections, the one write that may vouch for the store again, as it did for connections.json.
    @discardableResult
    func commit(
        _ proposed: LibraryImage,
        byUser: Bool = true,
        removingSecrets: Bool = false,
        removingUnreadable removedIds: Set<UUID> = []
    ) -> Bool {
        guard current() != nil, !lastLoadFailed, let library else {
            Self.logger.error("Refused to write the connection library: it could not be read")
            return false
        }
        // The core holds one record per id, and a second copy would take the first one's secrets.
        guard proposed.keepingFirstOfEachId() == proposed else {
            Self.logger.error("Refused a library write that names one id twice")
            return false
        }
        var next = proposed
        next.favoritesOrder = proposed.favorites(keeping: unreadableIds)
        let held = unreadableIds.subtracting(removedIds)
        if let taken = next.connections.first(where: { held.contains($0.id) }) {
            Self.logger.error("Refused a write over a connection this build cannot read: \(taken.id, privacy: .public)")
            return false
        }
        let change = Change(byUser: byUser, removingSecrets: removingSecrets, removedIds: removedIds)
        // The core carries what it does not show into every write: unknown keys, held entries, other sections. Only a
        // store rebuilt from what this Mac holds is one a person's save vouches for.
        if !byUser || isTrusted || !integrityKeyAnswered {
            switch replace(next, change, in: library) {
            case .written:
                return true
            case .failed:
                return false
            case .changed:
                // The file changed since this store read it: nothing is written over it, and the next read takes it in.
                isTrusted = false
                guard byUser, integrityKeyAnswered else {
                    image = nil
                    return false
                }
            }
        }
        return rebuild(next, change, in: library)
    }

    private struct Change {
        let byUser: Bool
        let removingSecrets: Bool
        let removedIds: Set<UUID>
    }

    private enum Outcome {
        case written
        case changed
        case failed
    }

    private func replace(_ next: LibraryImage, _ change: Change, in library: ConnectionLibrary) -> Outcome {
        if change.removingSecrets, !removeSetAsideCopies() {
            return .failed
        }
        let write = records(for: next, removing: change.removedIds.intersection(heldByCore))
        let over = seenDigest
        let written: LibraryWritten
        do {
            written = try Self.blocking { try await library.replaceLibrary(library: write, over: over) }
        } catch {
            Self.logger.error("The core refused the library write: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return Self.code(of: error) == "storage.library_changed" ? .changed : .failed
        }
        finish(next, write: write, written: written, stamping: isTrusted, change)
        return .written
    }

    private func rebuild(_ next: LibraryImage, _ change: Change, in library: ConnectionLibrary) -> Bool {
        var copy: URL?
        if FileManager.default.fileExists(atPath: coreFileURL.path) {
            guard let made = copyCoreFile(as: "untrusted") else { return false }
            copy = made
        }
        // Copies set aside still hold what a save that moves secrets out takes out of the store.
        if change.removingSecrets, !removeSetAsideCopies(keeping: copy) {
            discard(copy)
            return false
        }
        forgetCoreState()
        let write = records(for: next, removing: [])
        let written: LibraryWritten
        do {
            written = try Self.blocking { try await library.rebuildLibrary(library: write) }
        } catch {
            Self.logger.error("The core refused to rebuild the library: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            discard(copy)
            // What this store forgot about the file it meant to replace is read again.
            image = nil
            return false
        }
        if change.removingSecrets {
            discard(copy)
            discard(written.setAside.map { URL(fileURLWithPath: $0) })
        }
        finish(next, write: write, written: written, stamping: true, change)
        return true
    }

    private func finish(_ next: LibraryImage, write: LibraryWriteRecord, written: LibraryWritten, stamping: Bool, _ change: Change) {
        writeCount += 1
        seenDigest = written.digest
        rememberWritten(write)
        mirror.record = mirrorRecord(legacy: mirror.digest(), core: written.digest, legacyBehind: true)
        settleTag(written.digest, stamping: stamping)
        image = next
        updateLocalOnly(next)
        mirrorWrite(
            next,
            coreDigest: written.digest,
            byUser: change.byUser,
            removingSecrets: change.removingSecrets,
            removingUnreadable: change.removedIds
        )
    }

    // MARK: - Loading

    private func load() -> LibraryImage? {
        readCount += 1
        guard let library = openedLibrary() else { return failLoad() }
        let legacy = mirror.read()
        let legacyDigest = mirror.digest()
        integrityKeyAnswered = integrity.hasKey
        let contents: LibraryContents
        do {
            contents = try Self.blocking { try await library.libraryContents() }
        } catch {
            return loadUnreadable(error, legacy: legacy, legacyDigest: legacyDigest, into: library)
        }
        guard let coreDigest = contents.digest else {
            guard let legacy else {
                Self.logger.error("connections.json could not be read and the core holds no library yet")
                return failLoad()
            }
            return importLegacy(legacy, digest: legacyDigest, into: library, over: .noFile)
        }
        let verdict = integrity.verify(Self.tag(forDigest: coreDigest), fileURL: coreFileURL)
        let taggedOutside = verdict == .modified || verdict == .unstamped
        // The previous stable's stores, when they read and verify, hold what TablePro last wrote; a core file TablePro
        // did not tag never wins over them, whatever the mirror record says.
        if taggedOutside, let legacy, mirror.isTrusted, mirror.holdsConnectionsFile {
            return importLegacy(legacy, digest: legacyDigest, into: library, over: .rebuilding(copying: true))
        }
        if takesLegacy(legacyDigest: legacyDigest, coreDigest: coreDigest) {
            // A change this build cannot read is never written over, as connections.json has always been kept.
            guard let legacy else {
                Self.logger.error("The previous stable's library changed and could not be read; nothing is written over it")
                return failLoad()
            }
            if taggedOutside {
                return importLegacy(legacy, digest: legacyDigest, into: library, over: .rebuilding(copying: true))
            }
            remember(contents)
            return importLegacy(legacy, digest: legacyDigest, into: library, over: .file(coreDigest))
        }
        let loaded = adopt(contents, verdict: verdict)
        remirrorIfBehind(loaded, legacyDigest: legacyDigest, legacyReads: legacy != nil, coreDigest: coreDigest)
        return loaded
    }

    // A file a newer build wrote stays as it is, and so does one with nothing to rebuild it from. A damaged one comes back
    // from the previous stable's stores, which hold the library as last written; the rebuild sets it aside.
    private func loadUnreadable(
        _ error: any Error,
        legacy: LegacyLibraryMirror.Contents?,
        legacyDigest: String,
        into library: ConnectionLibrary
    ) -> LibraryImage? {
        Self.logger.error("The core could not read the connection library: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        guard let code = Self.code(of: error), Self.damageCodes.contains(code), let legacy, mirror.holdsConnectionsFile else {
            return failLoad()
        }
        return importLegacy(legacy, digest: legacyDigest, into: library, over: .rebuilding(copying: false))
    }

    nonisolated private static let damageCodes: Set<String> = [
        "storage.document_corrupt",
        "storage.document_missing_version",
        "storage.document_unreadable",
    ]

    // The previous stable writes only its own stores. A change there that the core's store did not see since the last
    // complete mirror is that build's, so the library comes back from them; any other mismatch is a write of this build's
    // that stopped before its mirror, and the core's store has it.
    private func takesLegacy(legacyDigest: String, coreDigest: String) -> Bool {
        guard let record = mirror.record, mirror.holdsConnectionsFile || !record.connectionsFileExisted else { return false }
        return record.legacy != legacyDigest && record.core == coreDigest
    }

    private enum ImportTarget {
        case noFile
        case file(String)
        // Copying keeps a readable file the rebuild replaces; one that does not read the core sets aside itself.
        case rebuilding(copying: Bool)
    }

    private func importLegacy(
        _ legacy: LegacyLibraryMirror.Contents,
        digest: String,
        into library: ConnectionLibrary,
        over target: ImportTarget
    ) -> LibraryImage? {
        if case .rebuilding(let copying) = target {
            if copying, FileManager.default.fileExists(atPath: coreFileURL.path), copyCoreFile(as: "untrusted") == nil {
                return failLoad()
            }
            forgetCoreState()
        }
        // A newer build wrote the core's copy of a connection it holds unread; the previous stable's is older.
        var imported = LibraryImage(
            connections: legacy.connections.filter { !heldByCore.contains($0.id) },
            groups: legacy.groups,
            tags: legacy.tags,
            favoritesOrder: legacy.favoritesOrder
        ).keepingFirstOfEachId()
        imported.favoritesOrder = imported.favorites(keeping: unreadableIds)
        let write = records(for: imported, removing: [])
        let written: LibraryWritten
        do {
            written = try Self.blocking {
                switch target {
                case .noFile: try await library.replaceLibrary(library: write, over: nil)
                case .file(let over): try await library.replaceLibrary(library: write, over: over)
                case .rebuilding: try await library.rebuildLibrary(library: write)
                }
            }
        } catch {
            Self.logger.error("The core refused the library from connections.json: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return failLoad()
        }
        writeCount += 1
        seenDigest = written.digest
        rememberWritten(write)
        // A file changed outside TablePro hands its verdict on; a missing tag must then read as modified, never adopted.
        settleTag(written.digest, stamping: mirror.isTrusted)
        image = imported
        updateLocalOnly(imported)
        mirror.record = mirrorRecord(legacy: digest, core: written.digest)
        lastLoadFailed = false
        Self.logger.info("Read the connection library from connections.json into the core")
        return imported
    }

    private func adopt(_ contents: LibraryContents, verdict: ConnectionStoreIntegrity.Verdict) -> LibraryImage {
        isTrusted = verdict == .trusted
        integrityKeyAnswered = verdict != .unavailable
        seenDigest = contents.digest
        remember(contents)
        let favorites = Set(contents.favorites.compactMap(UUID.init(uuidString:)))
        let loaded = LibraryImage(
            connections: contents.connections.map { record in
                LibraryRecordMapping.connection(
                    record,
                    isFavorite: UUID(uuidString: record.connection.id).map(favorites.contains) ?? false
                )
            },
            groups: contents.groups.map(LibraryRecordMapping.group),
            tags: contents.tags.map(LibraryRecordMapping.tag),
            favoritesOrder: contents.favorites.compactMap(UUID.init(uuidString:))
        )
        image = loaded
        updateLocalOnly(loaded)
        lastLoadFailed = false
        return loaded
    }

    // Tags the file a write left when asked. Any other write leaves no tag beside it, since an older one could still
    // match these bytes and vouch for what this write did not.
    private func settleTag(_ digest: String?, stamping: Bool) {
        if let digest, stamping {
            isTrusted = integrity.stamp(Self.tag(forDigest: digest), fileURL: coreFileURL)
            integrityKeyAnswered = isTrusted
            return
        }
        try? FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: coreFileURL))
        _ = integrity.recordTagged(fileURL: coreFileURL)
        isTrusted = false
    }

    // The core hands over the digest of the exact bytes it read or wrote, so the tag covers those and nothing read beside.
    nonisolated static func tag(forDigest digest: String) -> Data {
        Data("sha256:\(digest)".utf8)
    }

    // A write whose mirror did not land, or stores that no record describes, leave the previous stable reading an
    // older library; it gets the core's again before anyone can downgrade onto it.
    private func remirrorIfBehind(_ loaded: LibraryImage, legacyDigest: String, legacyReads: Bool, coreDigest: String) {
        guard legacyReads else { return }
        if let recorded = mirror.record {
            guard recorded.legacyBehind || recorded.legacy != legacyDigest || recorded.core != coreDigest else { return }
            if recorded.legacy != legacyDigest, recorded.core != coreDigest, mirror.holdsConnectionsFile {
                Self.logger.warning("The previous stable's stores changed while the core's did too; the core's library is kept")
            }
        }
        mirrorWrite(loaded, coreDigest: coreDigest, byUser: false, removingSecrets: false, removingUnreadable: [])
    }

    private func mirrorRecord(legacy: String, core: String?, legacyBehind: Bool = false) -> LegacyLibraryMirror.Record {
        LegacyLibraryMirror.Record(
            legacy: legacy,
            core: core ?? "",
            connectionsFileExisted: mirror.holdsConnectionsFile,
            legacyBehind: legacyBehind
        )
    }

    nonisolated private static func code(of error: any Error) -> String? {
        guard case CoreError.Failed(let info) = error else { return nil }
        return info.code
    }

    // Kept under its own name, never over an earlier one, so each copy that was set aside stays.
    private func copyCoreFile(as reason: String) -> URL? {
        let stamp = Self.asideStamp.string(from: Date())
        let aside = coreFileURL.deletingLastPathComponent()
            .appendingPathComponent("\(coreFileURL.lastPathComponent).\(reason)-\(stamp)-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.copyItem(at: coreFileURL, to: aside)
            Self.logger.warning("Kept a copy of Core/connections.json as \(reason, privacy: .public)")
            return aside
        } catch {
            Self.logger.error("Could not keep a copy of Core/connections.json: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    private func discard(_ copy: URL?) {
        guard let copy else { return }
        try? FileManager.default.removeItem(at: copy)
    }

    // This store's copies and the files the core set aside as unreadable.
    private func removeSetAsideCopies(keeping kept: URL? = nil) -> Bool {
        let folder = coreFileURL.deletingLastPathComponent()
        let prefix = "\(coreFileURL.lastPathComponent)."
        do {
            let copies = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { url in
                    let name = url.lastPathComponent
                    return name != kept?.lastPathComponent
                        && (name.hasPrefix(prefix + "untrusted-") || name.hasPrefix(prefix + "corrupt-"))
                }
            for copy in copies {
                try FileManager.default.removeItem(at: copy)
            }
            return true
        } catch {
            Self.logger.error("Could not remove the copies set aside before moving secrets out: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }

    private static let asideStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return formatter
    }()

    // Nothing a file being replaced held is carried into the write: no kept value, no held entry.
    private func forgetCoreState() {
        stored = [:]
        storedGroups = [:]
        storedTags = [:]
        heldByCore = []
    }

    private func openedLibrary() -> ConnectionLibrary? {
        if let library { return library }
        do {
            let opened = try host.core().library()
            library = opened
            return opened
        } catch {
            Self.logger.error("The core's connection library did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return nil
        }
    }

    private func failLoad() -> LibraryImage? {
        lastLoadFailed = true
        isTrusted = false
        image = nil
        return nil
    }

    // MARK: - State

    private func remember(_ contents: LibraryContents) {
        remember(connections: contents.connections, groups: contents.groups, tags: contents.tags)
        heldByCore = Set(contents.unreadable.compactMap(UUID.init(uuidString:)))
    }

    // The core holds what the write named, and the entries it held that the write did not take out.
    private func rememberWritten(_ write: LibraryWriteRecord) {
        remember(connections: write.connections, groups: write.groups, tags: write.tags)
        heldByCore.subtract(write.removing.compactMap(UUID.init(uuidString:)))
    }

    private func remember(connections: [LibraryConnectionRecord], groups: [GroupRecord], tags: [TagRecord]) {
        stored = Dictionary(
            connections.compactMap { record in UUID(uuidString: record.connection.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
        storedGroups = Dictionary(
            groups.compactMap { record in UUID(uuidString: record.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
        storedTags = Dictionary(
            tags.compactMap { record in UUID(uuidString: record.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func updateLocalOnly(_ image: LibraryImage) {
        localOnly.set(Set(image.connections.filter { !$0.participatesInSync }.map(\.id)))
    }

    private func records(for image: LibraryImage, removing: Set<UUID>) -> LibraryWriteRecord {
        LibraryWriteRecord(
            connections: image.connections.map { LibraryRecordMapping.record($0, keeping: stored[$0.id]) },
            groups: image.groups.map { LibraryRecordMapping.record($0, keeping: storedGroups[$0.id]) },
            tags: image.tags.map { LibraryRecordMapping.record($0, keeping: storedTags[$0.id]) },
            favorites: image.favorites(keeping: unreadableIds).map(\.uuidString),
            removing: removing.map(\.uuidString)
        )
    }

    private func mirrorWrite(
        _ image: LibraryImage,
        coreDigest: String?,
        byUser: Bool,
        removingSecrets: Bool,
        removingUnreadable removedIds: Set<UUID>
    ) {
        let contents = LegacyLibraryMirror.Contents(
            connections: image.connections,
            groups: image.groups,
            tags: image.tags,
            favoritesOrder: image.favoritesOrder
        )
        // Recorded first, so a launch after a crash here knows these stores are behind the core's.
        mirror.record = mirrorRecord(legacy: mirror.digest(), core: coreDigest, legacyBehind: true)
        // The copy vouches for no more than the store it copies.
        if !isTrusted {
            mirror.file.withdrawTrust()
        }
        guard mirror.write(
            contents,
            byUser: byUser && isTrusted,
            removingSecrets: removingSecrets,
            removingUnreadable: removedIds,
            connectionsWritten: { [self] in
                mirror.record = mirrorRecord(legacy: mirror.digest(), core: coreDigest, legacyBehind: true)
            }
        ) else {
            Self.logger.error("The previous stable's stores were not updated; the core's store has this write")
            return
        }
        mirror.record = mirrorRecord(legacy: mirror.digest(), core: coreDigest)
    }

    // MARK: - Calls into the core

    // The stores' API is synchronous on the main actor; the core's library calls are async and never reach the main
    // actor, so the wait cannot deadlock.
    nonisolated private static func blocking<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let outcome = OSAllocatedUnfairLock<Result<Value, any Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let result: Result<Value, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            outcome.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        guard let result = outcome.withLock({ $0 }) else {
            throw CoreLibraryStoreError.noAnswer
        }
        return try result.get()
    }
}

enum CoreLibraryStoreError: Error {
    case noAnswer
}
