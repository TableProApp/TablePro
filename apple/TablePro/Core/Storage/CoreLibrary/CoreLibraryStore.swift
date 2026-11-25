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

    private let storageDirectory: URL
    private let keychain: any KeychainStoring
    private let integrity: ConnectionStoreIntegrity
    private let clientVersion: String
    // Read on the core's threads by the keychain, so a Local only connection's secrets stay on this Mac.
    private let keptOnDevice = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    private var library: ConnectionLibrary?
    private var image: LibraryImage?
    // The records as the core last held them, for the values the Mac has no field for.
    private var stored: [UUID: LibraryConnectionRecord] = [:]
    private var storedGroups: [UUID: GroupRecord] = [:]
    private var storedTags: [UUID: TagRecord] = [:]
    private var heldByCore: Set<UUID> = []
    // The bytes this store last read or wrote, so a write can tell the file changed outside TablePro since.
    private var seenCoreDigest: String?
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
        integrity: ConnectionStoreIntegrity,
        clientVersion: String = CoreLibraryStore.appVersion
    ) {
        storageDirectory = legacyFileURL.deletingLastPathComponent().appendingPathComponent("Core", isDirectory: true)
        coreFileURL = storageDirectory.appendingPathComponent("connections.json")
        mirror = LegacyLibraryMirror(fileURL: legacyFileURL, defaults: defaults, integrity: integrity, logger: Self.logger)
        self.keychain = keychain
        self.integrity = integrity
        self.clientVersion = clientVersion
    }

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
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
        // The core carries what it does not show into every write: unknown keys, held entries, other sections. Once the
        // file changed outside TablePro, only a store rebuilt from what this Mac holds is one a person's save vouches for.
        if coreChangedSinceSeen() {
            isTrusted = false
        }
        let rebuilds = byUser && !isTrusted && integrityKeyAnswered
        var setAside: URL?
        if rebuilds {
            if FileManager.default.fileExists(atPath: coreFileURL.path) {
                guard let aside = setAsideCoreFile(as: "untrusted") else { return false }
                setAside = aside
            }
            forgetCoreState()
        }
        // Copies set aside still hold what a save that moves secrets out takes out of the store.
        if removingSecrets, !removeSetAsideCopies(keeping: setAside) {
            restore(setAside)
            return false
        }
        for id in removedIds.intersection(heldByCore) {
            do {
                try Self.blocking { try await library.delete(id: id.uuidString) }
                heldByCore.remove(id)
            } catch {
                Self.logger.error("Could not remove an unreadable connection: \(LogRedaction.publicDescription(of: error), privacy: .public)")
                restore(setAside)
                return false
            }
        }
        let write = records(for: next)
        do {
            try Self.blocking { try await library.replaceLibrary(library: write) }
        } catch {
            Self.logger.error("The core refused the library write: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            restore(setAside)
            return false
        }
        writeCount += 1
        let written = settleWrite(of: library, stamping: rebuilds || isTrusted)
        if removingSecrets, let setAside {
            try? FileManager.default.removeItem(at: setAside)
        }
        image = next
        updateKeptOnDevice(next)
        mirrorWrite(next, coreBytes: written, byUser: byUser, removingSecrets: removingSecrets, removingUnreadable: removedIds)
        return true
    }

    // MARK: - Loading

    private func load() -> LibraryImage? {
        readCount += 1
        guard let library = openedLibrary() else { return failLoad() }
        let legacy = mirror.read()
        let legacyDigest = mirror.digest()
        guard let coreBytes = try? Data(contentsOf: coreFileURL) else {
            guard let legacy else {
                Self.logger.error("connections.json could not be read and the core holds no library yet")
                return failLoad()
            }
            return importLegacy(legacy, digest: legacyDigest, into: library, replacing: false)
        }
        let verdict = integrity.verify(coreBytes, fileURL: coreFileURL)
        let taggedOutside = verdict == .modified || verdict == .unstamped
        // The previous stable's stores, when they read and verify, hold what TablePro last wrote; a core file TablePro
        // did not tag never wins over them, whatever the mirror record says.
        if taggedOutside, let legacy, mirror.isTrusted, mirror.holdsConnectionsFile {
            guard setAsideCoreFile(as: "untrusted") != nil else { return failLoad() }
            forgetCoreState()
            return importLegacy(legacy, digest: legacyDigest, into: library, replacing: false)
        }
        if takesLegacy(legacyDigest: legacyDigest, coreBytes: coreBytes) {
            // A change this build cannot read is never written over, as connections.json has always been kept.
            guard let legacy else {
                Self.logger.error("The previous stable's library changed and could not be read; nothing is written over it")
                return failLoad()
            }
            if taggedOutside {
                guard setAsideCoreFile(as: "untrusted") != nil else { return failLoad() }
                forgetCoreState()
            }
            return importLegacy(legacy, digest: legacyDigest, into: library, replacing: !taggedOutside)
        }
        if let loaded = readCore(library) {
            remirrorIfBehind(loaded, legacyDigest: legacyDigest, legacyReads: legacy != nil)
            return loaded
        }
        // A file TablePro tagged that the core cannot read is a newer build's and stays as it is. Any other comes back
        // from the previous stable's stores, which hold the library as last written.
        guard taggedOutside, let legacy, mirror.holdsConnectionsFile, setAsideCoreFile(as: "unreadable") != nil else {
            return failLoad()
        }
        forgetCoreState()
        return importLegacy(legacy, digest: legacyDigest, into: library, replacing: false)
    }

    // The previous stable writes only its own stores. A change there that the core's store did not see since the last
    // complete mirror is that build's, so the library comes back from them; any other mismatch is a write of this build's
    // that stopped before its mirror, and the core's store has it.
    private func takesLegacy(legacyDigest: String, coreBytes: Data?) -> Bool {
        guard let coreBytes else { return true }
        guard let record = mirror.record, mirror.holdsConnectionsFile || !record.connectionsFileExisted else { return false }
        return record.legacy != legacyDigest && record.core == LegacyLibraryMirror.digest(of: coreBytes)
    }

    private func importLegacy(
        _ legacy: LegacyLibraryMirror.Contents,
        digest: String,
        into library: ConnectionLibrary,
        replacing: Bool
    ) -> LibraryImage? {
        if replacing {
            guard let contents = contents(of: library) else { return failLoad() }
            remember(contents)
        }
        // A newer build wrote the core's copy of a connection it holds unread; the previous stable's is older.
        var imported = LibraryImage(
            connections: legacy.connections.filter { !heldByCore.contains($0.id) },
            groups: legacy.groups,
            tags: legacy.tags,
            favoritesOrder: legacy.favoritesOrder
        ).keepingFirstOfEachId()
        imported.favoritesOrder = imported.favorites(keeping: unreadableIds)
        let write = records(for: imported)
        do {
            try Self.blocking { try await library.replaceLibrary(library: write) }
        } catch {
            Self.logger.error("The core refused the library from connections.json: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return failLoad()
        }
        writeCount += 1
        // A file changed outside TablePro hands its verdict on; a missing tag must then read as modified, never adopted.
        let written = settleWrite(of: library, stamping: mirror.isTrusted)
        image = imported
        updateKeptOnDevice(imported)
        mirror.record = mirrorRecord(legacy: digest, core: written)
        lastLoadFailed = false
        Self.logger.info("Read the connection library from connections.json into the core")
        return imported
    }

    private func readCore(_ library: ConnectionLibrary) -> LibraryImage? {
        guard let read = bracketedContents(of: library) else { return failLoad() }
        let (contents, bytes) = read
        let verdict = bytes.map { integrity.verify($0, fileURL: coreFileURL) } ?? .modified
        isTrusted = verdict == .trusted
        integrityKeyAnswered = verdict != .unavailable
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
        updateKeptOnDevice(loaded)
        lastLoadFailed = false
        return loaded
    }

    // The core reads the file itself, so the bytes before and after its read stand for what it read only when they
    // match; otherwise there are none to verify.
    private func bracketedContents(of library: ConnectionLibrary) -> (LibraryContents, Data?)? {
        let before = try? Data(contentsOf: coreFileURL)
        guard let contents = contents(of: library) else { return nil }
        let after = try? Data(contentsOf: coreFileURL)
        guard let before, before == after else {
            seenCoreDigest = nil
            return (contents, nil)
        }
        seenCoreDigest = LegacyLibraryMirror.digest(of: before)
        return (contents, before)
    }

    // Reads back what the write left, tags it when asked, and returns the bytes the tag and the mirror record cover.
    private func settleWrite(of library: ConnectionLibrary, stamping: Bool) -> Data? {
        guard let read = bracketedContents(of: library) else {
            isTrusted = false
            return try? Data(contentsOf: coreFileURL)
        }
        let (contents, bytes) = read
        remember(contents)
        if let bytes, stamping {
            isTrusted = integrity.stamp(bytes, fileURL: coreFileURL)
            integrityKeyAnswered = isTrusted
        } else {
            // An older tag left beside these bytes could still match them and vouch for what this write did not.
            try? FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: coreFileURL))
            _ = integrity.recordTagged(fileURL: coreFileURL)
            isTrusted = false
        }
        return bytes
    }

    // A write whose mirror did not land, or stores that no record describes, leave the previous stable reading an
    // older library; it gets the core's again before anyone can downgrade onto it.
    private func remirrorIfBehind(_ loaded: LibraryImage, legacyDigest: String, legacyReads: Bool) {
        guard legacyReads else { return }
        let coreBytes = try? Data(contentsOf: coreFileURL)
        if let recorded = mirror.record {
            let coreDigest = LegacyLibraryMirror.digest(of: coreBytes)
            guard recorded.legacyBehind || recorded.legacy != legacyDigest || recorded.core != coreDigest else { return }
            if recorded.legacy != legacyDigest, recorded.core != coreDigest, mirror.holdsConnectionsFile {
                Self.logger.warning("The previous stable's stores changed while the core's did too; the core's library is kept")
            }
        }
        mirrorWrite(loaded, coreBytes: coreBytes, byUser: false, removingSecrets: false, removingUnreadable: [])
    }

    private func mirrorRecord(legacy: String, core: Data?, legacyBehind: Bool = false) -> LegacyLibraryMirror.Record {
        LegacyLibraryMirror.Record(
            legacy: legacy,
            core: LegacyLibraryMirror.digest(of: core),
            connectionsFileExisted: mirror.holdsConnectionsFile,
            legacyBehind: legacyBehind
        )
    }

    private func coreChangedSinceSeen() -> Bool {
        LegacyLibraryMirror.digest(of: try? Data(contentsOf: coreFileURL)) != seenCoreDigest
    }

    private func contents(of library: ConnectionLibrary) -> LibraryContents? {
        do {
            return try Self.blocking { try await library.libraryContents() }
        } catch {
            Self.logger.error("The core could not read the connection library: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return nil
        }
    }

    // Kept under its own name, never over an earlier one, so each copy that was set aside stays.
    private func setAsideCoreFile(as reason: String) -> URL? {
        let stamp = Self.asideStamp.string(from: Date())
        let aside = coreFileURL.deletingLastPathComponent()
            .appendingPathComponent("\(coreFileURL.lastPathComponent).\(reason)-\(stamp)-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.moveItem(at: coreFileURL, to: aside)
            Self.logger.warning("Set aside Core/connections.json as \(reason, privacy: .public)")
            return aside
        } catch {
            Self.logger.error("Could not set aside Core/connections.json: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    // A write that did not land leaves the store as it was, so the file set aside for it goes back.
    private func restore(_ aside: URL?) {
        guard let aside else { return }
        do {
            try FileManager.default.moveItem(at: aside, to: coreFileURL)
        } catch {
            Self.logger.error("Could not put back Core/connections.json: \(error.publicLogShape, privacy: .public)")
        }
    }

    private func removeSetAsideCopies(keeping kept: URL?) -> Bool {
        let folder = coreFileURL.deletingLastPathComponent()
        let prefix = "\(coreFileURL.lastPathComponent)."
        do {
            let copies = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { url in
                    let name = url.lastPathComponent
                    return url.lastPathComponent != kept?.lastPathComponent
                        && (name.hasPrefix(prefix + "unreadable-") || name.hasPrefix(prefix + "untrusted-"))
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

    // Nothing a file that was set aside held is carried into the next write: no kept value, no held entry.
    private func forgetCoreState() {
        stored = [:]
        storedGroups = [:]
        storedTags = [:]
        heldByCore = []
        seenCoreDigest = nil
    }

    private func openedLibrary() -> ConnectionLibrary? {
        if let library { return library }
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let keptOnDevice = keptOnDevice
            let secrets = ConnectionKeychainSecrets(keychain: keychain) { id in
                keptOnDevice.withLock { $0.contains(id) }
            }
            let core = try Core(
                config: HostConfig(clientVersion: clientVersion, storageDir: storageDirectory.path),
                secrets: secrets
            )
            let opened = try core.library()
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
        stored = Dictionary(
            contents.connections.compactMap { record in UUID(uuidString: record.connection.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
        storedGroups = Dictionary(
            contents.groups.compactMap { record in UUID(uuidString: record.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
        storedTags = Dictionary(
            contents.tags.compactMap { record in UUID(uuidString: record.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
        heldByCore = Set(contents.unreadable.compactMap(UUID.init(uuidString:)))
    }

    private func updateKeptOnDevice(_ image: LibraryImage) {
        let ids = Set(image.connections.filter { !$0.participatesInSync }.map(\.id))
        keptOnDevice.withLock { $0 = ids }
    }

    private func records(for image: LibraryImage) -> LibraryWriteRecord {
        LibraryWriteRecord(
            connections: image.connections.map { LibraryRecordMapping.record($0, keeping: stored[$0.id]) },
            groups: image.groups.map { LibraryRecordMapping.record($0, keeping: storedGroups[$0.id]) },
            tags: image.tags.map { LibraryRecordMapping.record($0, keeping: storedTags[$0.id]) },
            favorites: image.favorites(keeping: unreadableIds).map(\.uuidString)
        )
    }

    private func mirrorWrite(
        _ image: LibraryImage,
        coreBytes: Data?,
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
        mirror.record = mirrorRecord(legacy: mirror.digest(), core: coreBytes, legacyBehind: true)
        // The copy vouches for no more than the store it copies.
        if !isTrusted {
            mirror.file.withdrawTrust()
        }
        guard mirror.write(
            contents,
            byUser: byUser && isTrusted,
            removingSecrets: removingSecrets,
            removingUnreadable: removedIds
        ) else {
            Self.logger.error("The previous stable's stores were not updated; the core's store has this write")
            return
        }
        mirror.record = mirrorRecord(legacy: mirror.digest(), core: coreBytes)
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
