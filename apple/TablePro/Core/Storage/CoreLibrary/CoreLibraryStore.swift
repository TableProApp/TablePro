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
    private var coreFileIsDamaged = false

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

    // False when the core did not take the write; nothing else is written then.
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
        var next = proposed
        next.favoritesOrder = proposed.favorites(keeping: unreadableIds)
        let held = unreadableIds.subtracting(removedIds)
        if let taken = next.connections.first(where: { held.contains($0.id) }) {
            Self.logger.error("Refused a write over a connection this build cannot read: \(taken.id, privacy: .public)")
            return false
        }
        for id in removedIds.intersection(heldByCore) {
            do {
                try Self.blocking { try await library.delete(id: id.uuidString) }
                heldByCore.remove(id)
            } catch {
                Self.logger.error("Could not remove an unreadable connection: \(LogRedaction.publicDescription(of: error), privacy: .public)")
                return false
            }
        }
        let write = records(for: next)
        do {
            try Self.blocking { try await library.replaceLibrary(library: write) }
        } catch {
            Self.logger.error("The core refused the library write: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
        writeCount += 1
        let coreBytes = try? Data(contentsOf: coreFileURL)
        if byUser || isTrusted, let coreBytes {
            isTrusted = integrity.stamp(coreBytes, fileURL: coreFileURL)
        }
        adopt(next, records: write)
        mirrorWrite(next, coreBytes: coreBytes, byUser: byUser, removingSecrets: removingSecrets, removingUnreadable: removedIds)
        return true
    }

    // MARK: - Loading

    private func load() -> LibraryImage? {
        readCount += 1
        guard let library = openedLibrary() else { return failLoad() }
        let legacy = mirror.read()
        let legacyDigest = mirror.digest()
        let coreBytes = try? Data(contentsOf: coreFileURL)
        guard takesLegacy(legacyDigest: legacyDigest, coreBytes: coreBytes) else {
            if let loaded = readCore(library) { return loaded }
            // The previous stable's stores hold the library as last written, so a core file that no longer parses
            // is set aside and the library comes back from them, as connections.json came back from its backup.
            guard coreFileIsDamaged, let legacy, setAsideCoreFile() else { return failLoad() }
            return importLegacy(legacy, digest: legacyDigest, into: library, replacing: false)
        }
        // A change this build cannot read is never written over, as connections.json has always been kept.
        guard let legacy else {
            Self.logger.error("The previous stable's library changed and could not be read; nothing is written over it")
            return failLoad()
        }
        return importLegacy(legacy, digest: legacyDigest, into: library, replacing: coreBytes != nil)
    }

    // The previous stable writes only its own stores. A change there that the core's store did not see since the last
    // complete mirror is that build's, so the library comes back from them; any other mismatch is a write of this build's
    // that stopped before its mirror, and the core's store has it.
    private func takesLegacy(legacyDigest: String, coreBytes: Data?) -> Bool {
        guard let coreBytes else { return true }
        guard mirror.holdsConnectionsFile, let record = mirror.record else { return false }
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
        )
        imported.favoritesOrder = imported.favorites(keeping: unreadableIds)
        let write = records(for: imported)
        do {
            try Self.blocking { try await library.replaceLibrary(library: write) }
        } catch {
            Self.logger.error("The core refused the library from connections.json: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return failLoad()
        }
        writeCount += 1
        let coreBytes = try? Data(contentsOf: coreFileURL)
        // A file changed outside TablePro hands its verdict on; a missing tag must then read as modified, never adopted.
        if mirror.isTrusted, let coreBytes {
            isTrusted = integrity.stamp(coreBytes, fileURL: coreFileURL)
        } else {
            _ = integrity.recordTagged(fileURL: coreFileURL)
            isTrusted = false
        }
        adopt(imported, records: write)
        mirror.record = LegacyLibraryMirror.Record(legacy: digest, core: LegacyLibraryMirror.digest(of: coreBytes))
        lastLoadFailed = false
        Self.logger.info("Read the connection library from connections.json into the core")
        return imported
    }

    private func readCore(_ library: ConnectionLibrary) -> LibraryImage? {
        let before = try? Data(contentsOf: coreFileURL)
        guard let contents = contents(of: library) else { return failLoad() }
        let after = try? Data(contentsOf: coreFileURL)
        // Verified on the bytes the core read: a file swapped between the two reads proves nothing.
        if let before, before == after {
            isTrusted = integrity.verify(before, fileURL: coreFileURL) == .trusted
        } else {
            isTrusted = false
        }
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

    private func contents(of library: ConnectionLibrary) -> LibraryContents? {
        coreFileIsDamaged = false
        do {
            return try Self.blocking { try await library.libraryContents() }
        } catch {
            if case .Failed(let info)? = error as? CoreError, info.code == "storage.document_unavailable" {
                coreFileIsDamaged = true
            }
            Self.logger.error("The core could not read the connection library: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return nil
        }
    }

    private func setAsideCoreFile() -> Bool {
        let aside = coreFileURL.appendingPathExtension("unreadable")
        do {
            if FileManager.default.fileExists(atPath: aside.path) {
                try FileManager.default.removeItem(at: aside)
            }
            try FileManager.default.moveItem(at: coreFileURL, to: aside)
            Self.logger.warning("Set aside a Core/connections.json that no longer parses as connections.json.unreadable")
            return true
        } catch {
            Self.logger.error("Could not set aside a damaged Core/connections.json: \(error.publicLogShape, privacy: .public)")
            return false
        }
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

    private func adopt(_ next: LibraryImage, records write: LibraryWriteRecord) {
        image = next
        remember(LibraryContents(
            connections: write.connections,
            groups: write.groups,
            tags: write.tags,
            favorites: write.favorites,
            unreadable: heldByCore.map(\.uuidString)
        ))
        updateKeptOnDevice(next)
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
        guard mirror.write(contents, byUser: byUser, removingSecrets: removingSecrets, removingUnreadable: removedIds) else {
            Self.logger.error("The previous stable's stores were not updated; the core's store has this write")
            return
        }
        mirror.record = LegacyLibraryMirror.Record(legacy: mirror.digest(), core: LegacyLibraryMirror.digest(of: coreBytes))
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
