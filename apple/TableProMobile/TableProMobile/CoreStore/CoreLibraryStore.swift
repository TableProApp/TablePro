import Foundation
import os
import TableProDatabase
import TableProFFI
import TableProLogRedaction
import TableProModels

// The connection library in the core's store (core ADRs 0010 and 0054): connections, groups, tags and favourites in one
// file, read whole and written whole, with the previous stable's files kept in step after each write.
@MainActor
final class CoreLibraryStore {
    struct Library: Equatable {
        var connections: [DatabaseConnection]
        var groups: [ConnectionGroup]
        var tags: [ConnectionTag]
    }

    enum Failure: Error, Equatable {
        case notLoaded
        case repeatedId
        case heldByUnreadableRecord(UUID)
        case noAnswer
        case libraryChanged
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CoreLibraryStore")

    // The codes a file the core cannot parse carries, as against one it cannot open or a newer build's.
    nonisolated static let damagedFileCodes: Set<String> = [
        "storage.document_corrupt",
        "storage.document_missing_version",
        "storage.document_unsupported_version",
        "storage.document_upgrade_failed",
    ]

    let coreFileURL: URL
    let mirror: LegacyLibraryMirror

    private let storageDirectory: URL
    private let defaults: UserDefaults
    private let secureStore: any SecureStore
    private let clientVersion: String

    private var library: ConnectionLibrary?
    private var loaded = false
    // The records as the core last held them, for the values iOS has no field for.
    private var stored: [UUID: LibraryConnectionRecord] = [:]
    private var storedGroups: [UUID: GroupRecord] = [:]
    private var storedTags: [UUID: TagRecord] = [:]
    private var storedFavorites: [UUID] = []
    private var heldByCore: Set<UUID> = []
    // The digest of the core's file as this store last read or wrote it; a write over another file is refused.
    private var fileDigest: String?
    // The previous stable's copies of connections the core holds unread, which every mirror write keeps.
    private var legacyCopiesOfHeld: [DatabaseConnection] = []
    private var flags = ConnectionDeviceFlags()
    private var secretCopiesPending = false

    // Pasted SSH keys an older build left in connections.json that the Keychain has not taken yet.
    private(set) var pastedSSHKeys: [UUID: String] = [:]

    init(
        directory: URL,
        defaults: UserDefaults,
        secureStore: any SecureStore,
        clientVersion: String = CoreLibraryStore.appVersion
    ) {
        storageDirectory = directory.appendingPathComponent("Core", isDirectory: true)
        coreFileURL = storageDirectory.appendingPathComponent("connections.json")
        mirror = LegacyLibraryMirror(directory: directory, defaults: defaults)
        self.defaults = defaults
        self.secureStore = secureStore
        self.clientVersion = clientVersion
    }

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var unreadableCopyURL: URL {
        coreFileURL.appendingPathExtension("unreadable")
    }

    // Records this build cannot read, in the core's store or in the previous stable's files; their ids stay taken.
    var unreadable: UnreadableCopies {
        var copies = mirror.unreadable
        copies.connections.formUnion(heldByCore)
        return copies
    }

    // MARK: - Loading

    // Throws when the library cannot be read: a device locked since restart, a newer build's file, or files the
    // previous stable changed that no longer read. Nothing is written over it then.
    func load() throws -> Library {
        loaded = false
        let library = try openedLibrary()
        let legacy = try mirror.read()
        pastedSSHKeys = legacy.pastedSSHKeys
        legacyCopiesOfHeld = []
        let legacyDigest = mirror.digest()
        flags = ConnectionDeviceFlags(defaults: defaults)

        // The core reads a blank file as an empty library, and its own writes never leave one, so one is damage.
        if let bytes = try? Data(contentsOf: coreFileURL), bytes.allSatisfy(Self.asciiWhitespace.contains) {
            try setAsideDamagedCoreFile()
            forgetCoreState()
            return try importLegacy(legacy, into: library)
        }
        let contents: LibraryContents
        do {
            contents = try Self.blocking { try await library.libraryContents() }
        } catch {
            guard Self.isDamaged(error) else {
                Self.logger.error("The core could not read the connection library: \(LogRedaction.publicDescription(of: error), privacy: .public)")
                throw error
            }
            try setAsideDamagedCoreFile()
            forgetCoreState()
            return try importLegacy(legacy, into: library)
        }
        guard let coreDigest = contents.digest else {
            forgetCoreState()
            return try importLegacy(legacy, into: library)
        }
        remember(contents)
        legacyCopiesOfHeld = legacy.connections.filter { heldByCore.contains($0.id) }
        // The previous stable writes only its own files. A change there the core's store did not see since this build
        // last wrote them, a file at a time, is that build's, so the library comes back from them.
        if let record = mirror.record, record.core == coreDigest, record.legacy != legacyDigest,
           record.legacyPending != legacyDigest {
            return try importLegacy(legacy, into: library)
        }
        let image = image(of: contents)
        loaded = true
        if mirror.record != LegacyLibraryMirror.Record(legacy: legacyDigest, core: coreDigest, legacyBehind: false) {
            do {
                try mirrorWrite(image, coreDigest: coreDigest, removingSecrets: false, removingUnreadable: UnreadableCopies())
            } catch {
                mirror.logBehind(error)
            }
        }
        return image
    }

    private func importLegacy(_ legacy: LegacyLibraryMirror.Contents, into library: ConnectionLibrary) throws -> Library {
        // A newer build wrote the core's copy of a connection it holds unread; the previous stable's is older.
        let readable = legacy.connections.filter { !heldByCore.contains($0.id) }
        // Connection-string secrets an older Mac synced move to the Keychain before the core's file first holds them.
        let cleaned = readable.map { MongoURISecretMigration.keepingSecretsInKeychain($0, in: secureStore) }
        let imported = Library(connections: cleaned, groups: legacy.groups, tags: legacy.tags)
        if cleaned != readable {
            try removeSecretCopies()
        }
        flags = ConnectionDeviceFlags(of: imported.connections).keeping(heldByCore, from: flags)
        let digest = try replace(with: imported, favoritesOrder: favoritesOrder, in: library)
        loaded = true
        if cleaned != readable {
            do {
                try mirrorWrite(imported, coreDigest: digest ?? "", removingSecrets: true, removingUnreadable: UnreadableCopies())
            } catch {
                mirror.logBehind(error)
            }
        } else {
            mirror.record = LegacyLibraryMirror.Record(legacy: mirror.digest(), core: digest ?? "", legacyBehind: false)
        }
        Self.logger.info("Read the connection library from the previous stable's files into the core")
        return imported
    }

    // MARK: - Writing

    // `removingSecrets` first deletes every copy that could still hold what this write takes out, or writes nothing.
    // `removingUnreadable` drops kept records by id, as a deletion another device made does.
    func write(
        _ next: Library,
        keepingPastedSSHKeys pasted: [UUID: String],
        removingSecrets: Bool = false,
        removingUnreadable removed: UnreadableCopies = UnreadableCopies()
    ) throws {
        guard loaded, let library else { throw Failure.notLoaded }
        guard Set(next.connections.map(\.id)).count == next.connections.count,
              Set(next.groups.map(\.id)).count == next.groups.count,
              Set(next.tags.map(\.id)).count == next.tags.count else {
            Self.logger.error("Refused a library write that names one id twice")
            throw Failure.repeatedId
        }
        let held = unreadable
        let stillHeld = UnreadableCopies(
            connections: held.connections.subtracting(removed.connections),
            groups: held.groups.subtracting(removed.groups),
            tags: held.tags.subtracting(removed.tags)
        )
        if let taken = next.connections.map(\.id).first(where: stillHeld.connections.contains)
            ?? next.groups.map(\.id).first(where: stillHeld.groups.contains)
            ?? next.tags.map(\.id).first(where: stillHeld.tags.contains) {
            Self.logger.error("Refused a write over a record this build cannot read: \(taken, privacy: .public)")
            throw Failure.heldByUnreadableRecord(taken)
        }
        // Before anything is written, so a write that takes secrets out leaves no older copy holding them. Until the
        // copies are gone every later write tries again.
        if removingSecrets || secretCopiesPending {
            try removeSecretCopies()
        }
        let unread = removed.connections.intersection(heldByCore)
        if !unread.isEmpty {
            // A delete goes over whatever file is there, so it waits for the file to still be the one this store read.
            let over = fileDigest
            let current = try Self.blocking { try await library.libraryContents() }.digest
            guard current == over else { throw Failure.libraryChanged }
        }
        for id in unread {
            try Self.blocking { try await library.delete(id: id.uuidString) }
            heldByCore.remove(id)
            legacyCopiesOfHeld.removeAll { $0.id == id }
            // After each delete, so one that fails later leaves the digest at the file the others left.
            fileDigest = try Self.blocking { try await library.libraryContents() }.digest
        }
        flags = ConnectionDeviceFlags(of: next.connections).keeping(heldByCore, from: flags)
        let digest = try replace(with: next, favoritesOrder: favoritesOrder, in: library)
        pastedSSHKeys = pasted
        do {
            try mirrorWrite(next, coreDigest: digest ?? "", removingSecrets: removingSecrets, removingUnreadable: removed)
        } catch {
            mirror.logBehind(error)
            // A removal the files did not take is retried with the next write; a launch would only copy them again.
            let legacyHeld = mirror.unreadable
            if removingSecrets || !removed.connections.isDisjoint(with: legacyHeld.connections)
                || !removed.groups.isDisjoint(with: legacyHeld.groups) || !removed.tags.isDisjoint(with: legacyHeld.tags) {
                throw error
            }
        }
    }

    private func replace(with next: Library, favoritesOrder: [UUID], in library: ConnectionLibrary) throws -> String? {
        let write = LibraryWriteRecord(
            connections: next.connections.map { LibraryRecordMapping.record($0, keeping: stored[$0.id]) },
            groups: next.groups.map { LibraryRecordMapping.record($0, keeping: storedGroups[$0.id]) },
            tags: next.tags.map { LibraryRecordMapping.record($0, keeping: storedTags[$0.id]) },
            favorites: favorites(of: next.connections, order: favoritesOrder).map(\.uuidString)
        )
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let over = fileDigest
            let written = try Self.blocking { try await library.replaceLibrary(library: write, over: over) }
            fileDigest = written.digest
            let contents = try Self.blocking { try await library.libraryContents() }
            // Another writer's file in between is not this write's to take in; the next write is refused over it.
            if contents.digest == written.digest {
                remember(contents)
            }
            flags.save(to: defaults)
            return written.digest
        } catch {
            Self.logger.error("The core refused the library write: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            throw error
        }
    }

    // The order this device shows its favourites in, then the rest as listed; favourites this build cannot read keep
    // their place in the core's list after them.
    private func favorites(of connections: [DatabaseConnection], order: [UUID]) -> [UUID] {
        let favoriteIds = Set(connections.filter(\.isFavorite).map(\.id))
        var seen: Set<UUID> = []
        var list = order.filter { favoriteIds.contains($0) && seen.insert($0).inserted }
        list += connections.map(\.id).filter { favoriteIds.contains($0) && seen.insert($0).inserted }
        list += storedFavorites.filter { heldByCore.contains($0) && seen.insert($0).inserted }
        return list
    }

    private var favoritesOrder: [UUID] {
        (defaults.stringArray(forKey: ConnectionLibraryPreferences.favoritesOrderKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func mirrorWrite(
        _ library: Library,
        coreDigest: String,
        removingSecrets: Bool,
        removingUnreadable removed: UnreadableCopies
    ) throws {
        // Recorded before and after each file, so a launch after a stop here tells the files this build left half
        // written from ones the previous stable changed.
        let behind = { [mirror] in
            mirror.record = LegacyLibraryMirror.Record(legacy: mirror.digest(), core: coreDigest, legacyBehind: true)
        }
        behind()
        try mirror.write(
            LegacyLibraryMirror.Contents(
                connections: library.connections + legacyCopiesOfHeld,
                groups: library.groups,
                tags: library.tags,
                pastedSSHKeys: pastedSSHKeys
            ),
            removingSecrets: removingSecrets,
            removingUnreadable: removed,
            willWrite: { [mirror] name, data in
                mirror.record = LegacyLibraryMirror.Record(
                    legacy: mirror.digest(),
                    core: coreDigest,
                    legacyBehind: true,
                    legacyPending: mirror.digest(replacing: name, with: data)
                )
            },
            wroteFile: behind
        )
        mirror.record = LegacyLibraryMirror.Record(legacy: mirror.digest(), core: coreDigest, legacyBehind: false)
    }

    // MARK: - State

    private func image(of contents: LibraryContents) -> Library {
        let favorites = Set(contents.favorites.compactMap(UUID.init(uuidString:)))
        return Library(
            connections: contents.connections.map { record in
                LibraryRecordMapping.connection(
                    record,
                    isFavorite: UUID(uuidString: record.connection.id).map(favorites.contains) ?? false,
                    flags: flags
                )
            },
            groups: contents.groups.map(LibraryRecordMapping.group),
            tags: contents.tags.map(LibraryRecordMapping.tag)
        )
    }

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
        storedFavorites = contents.favorites.compactMap(UUID.init(uuidString:))
        heldByCore = Set(contents.unreadable.compactMap(UUID.init(uuidString:)))
        fileDigest = contents.digest
    }

    // Until every copy is gone each later write tries again.
    private func removeSecretCopies() throws {
        secretCopiesPending = true
        try removeIfPresent(unreadableCopyURL)
        try mirror.removeSecretCopies()
        secretCopiesPending = false
    }

    // Nothing a file that was set aside held is carried into the next write.
    private func forgetCoreState() {
        stored = [:]
        storedGroups = [:]
        storedTags = [:]
        storedFavorites = []
        heldByCore = []
        legacyCopiesOfHeld = []
        fileDigest = nil
    }

    // The damaged file is kept beside the store, as the library files keep theirs; the next one replaces it.
    private func setAsideDamagedCoreFile() throws {
        Self.logger.warning("Core/connections.json no longer parses; it is set aside and the library comes back from connections.json")
        try removeIfPresent(unreadableCopyURL)
        try FileManager.default.moveItem(at: coreFileURL, to: unreadableCopyURL)
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private func openedLibrary() throws -> ConnectionLibrary {
        if let library { return library }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let core = try Core(
            config: HostConfig(clientVersion: clientVersion, storageDir: storageDirectory.path),
            secrets: ConnectionKeychainSecrets(secureStore: secureStore)
        )
        let opened = try core.library()
        library = opened
        return opened
    }

    // As Rust's `is_ascii_whitespace`, which the core's reader skips.
    nonisolated private static let asciiWhitespace: Set<UInt8> = [0x09, 0x0A, 0x0C, 0x0D, 0x20]

    nonisolated static func isDamaged(_ error: any Error) -> Bool {
        guard case let CoreError.Failed(info) = error else { return false }
        return damagedFileCodes.contains(info.code)
    }

    // MARK: - Calls into the core

    // The library's API is synchronous on the main actor, as the files it replaces were; the core's calls are async and
    // never reach the main actor, so the wait cannot deadlock.
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
        guard let result = outcome.withLock({ $0 }) else { throw Failure.noAnswer }
        return try result.get()
    }
}
