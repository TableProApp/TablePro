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
    private let profileSecrets: ProfileKeychainSecrets
    private let integrity: ConnectionStoreIntegrity

    private var library: ConnectionLibrary?
    private var image: LibraryImage?
    // The records as the core last held them, for the values the Mac has no field for.
    private var stored: [UUID: LibraryConnectionRecord] = [:]
    private var storedGroups: [UUID: GroupRecord] = [:]
    private var storedTags: [UUID: TagRecord] = [:]
    private var storedProjects: [UUID: ProjectRecord] = [:]
    private var storedSSHProfiles: [UUID: SshProfileRecord] = [:]
    // Profiles the core holds that this build cannot read; a write that names one is refused.
    private var heldProfiles: Set<UUID> = []
    private var heldByCore: Set<UUID> = []
    // The previous stable's copies of connections the core holds unread, kept in its file as they are.
    private var legacyHeld: [DatabaseConnection] = []
    // The digest of the file as this store last read or wrote it; the core refuses a write over any other.
    private var seenDigest: String?
    // False while no integrity key can be had: a store rebuilt then could not be tagged either.
    private var integrityKeyAnswered = true

    private(set) var lastLoadFailed = false
    // False until a load answers, so nothing reads "trusted" for a store nobody verified.
    private(set) var isTrusted = false
    // The credential profiles have a seal of their own, as credentialProfiles.json had its own tag: a profile can name a
    // command, and no save but one over profiles TablePro wrote keeps them vouched for, a person's connection save included.
    private(set) var profilesTrusted = false
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
        let opened = Self.coreHost(over: folder, keychain: keychain, integrity: integrity)
        host = opened.host
        localOnly = opened.localOnly
        profileSecrets = opened.profileSecrets
    }

    // The app's library opens on the core every store over `TablePro/Core` shares, so no second runtime holds its files;
    // a library anywhere else gets a core of its own.
    private static func coreHost(
        over folder: URL,
        keychain: any KeychainStoring,
        integrity: ConnectionStoreIntegrity
    ) -> (host: CoreStoreHost, localOnly: LocalOnlyConnections, profileSecrets: ProfileKeychainSecrets) {
        if folder.standardizedFileURL == CoreStoreHost.shared.folder.standardizedFileURL {
            return (.shared, .shared, .shared)
        }
        let localOnly = LocalOnlyConnections()
        let profileSecrets = ProfileKeychainSecrets(keychain: keychain)
        let host = CoreStoreHost(
            folder: folder,
            makeSecrets: {
                CoreStoreSecrets(
                    items: nil,
                    connections: ConnectionKeychainSecrets(keychain: keychain) { id in localOnly.isLocalOnly(id) },
                    profiles: profileSecrets
                )
            },
            reportKey: { integrity.libraryReportKey() }
        )
        return (host, localOnly, profileSecrets)
    }

    // Records this build cannot read, in the core's store or in connections.json; what belongs to them is kept.
    var unreadableIds: Set<UUID> {
        heldByCore.union(mirror.unreadableIds)
    }

    // Profiles this build cannot read, in the core's store or in credentialProfiles.json; their ids stay taken.
    var unreadableProfileIds: Set<UUID> {
        heldProfiles.union(mirror.unreadableProfileIds)
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

    // The core's engine writes the library itself, so after its pass the file is read again when its digest moved. It
    // is tagged when the core reports that write as its own, made over a file this store vouched for; any other change
    // leaves it untrusted until a person's connection save rebuilds it.
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
        let vouched = digestsTheCoreVouchesFor()
        guard let digest = contents.digest, digest != seenDigest else { return false }
        readCount += 1
        let before = image?.connections ?? []
        let loaded: LibraryImage
        if vouched.contains(digest) {
            let profilesWere = profilesTrusted
            loaded = adopt(contents, verdict: .trusted)
            settleTag(digest, stamping: true)
            profilesTrusted = profilesWere
            settleProfilesSeal(loaded.credentialProfiles)
        } else {
            loaded = adopt(contents, verdict: integrityKeyAnswered ? .modified : .unavailable)
        }
        // One a pull made unreadable here keeps the copy the previous stable last had.
        let keptIds = Set(legacyHeld.map(\.id))
        legacyHeld += before.filter { heldByCore.contains($0.id) && !keptIds.contains($0.id) }
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
        let profileIds = next.sshProfiles.map(\.id) + next.credentialProfiles.map(\.id)
        if let taken = profileIds.first(where: { unreadableProfileIds.subtracting(removedIds).contains($0) }) {
            Self.logger.error("Refused a write over a profile this build cannot read: \(taken, privacy: .public)")
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
                // The file changed since this store read it. Only a person's save goes on, rebuilding it from what this
                // store read when it was trusted; anything else is refused, and the next read takes the file in.
                isTrusted = false
                guard byUser, integrityKeyAnswered else {
                    image = nil
                    return false
                }
                return rebuild(next, change, keepingStoredValues: true, in: library)
            }
        }
        return rebuild(next, change, keepingStoredValues: false, in: library)
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

    private func rebuild(
        _ next: LibraryImage,
        _ change: Change,
        keepingStoredValues: Bool,
        in library: ConnectionLibrary
    ) -> Bool {
        // A rebuild sets aside any file the core cannot read, so a newer build's file is checked for first.
        guard !holdsNewerFile(library) else {
            Self.logger.error("Refused to rebuild the library over a file a newer TablePro wrote")
            image = nil
            return false
        }
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
        if keepingStoredValues {
            heldByCore = []
        } else {
            forgetCoreState()
        }
        // The held connections the rebuild drops leave the favourites order too.
        var next = next
        next.favoritesOrder = next.favorites(keeping: unreadableIds)
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
        // Tagged before the record names the new file, so a stop between the two leaves a trusted file the record calls
        // newer than the mirror, which the next launch writes again.
        settleTag(written.digest, stamping: stamping)
        settleProfilesSeal(next.credentialProfiles)
        mirror.record = mirrorRecord(legacy: mirror.digest(), core: written.digest, legacyBehind: true)
        // The core keeps a copy of a file it upgrades as it writes, which still holds what this write moved out.
        if change.removingSecrets {
            _ = removeSetAsideCopies()
        }
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
        var verdict = integrity.verify(Self.tag(forDigest: coreDigest), fileURL: coreFileURL)
        // The core's own writes since this store last tagged the file, a pull's before a quit among them.
        if verdict != .trusted, digestsTheCoreVouchesFor().contains(coreDigest),
           integrity.stamp(Self.tag(forDigest: coreDigest), fileURL: coreFileURL) {
            verdict = .trusted
        }
        let taggedOutside = verdict == .modified || verdict == .unstamped
        // The previous stable's stores, when they read and verify, hold what TablePro last wrote; a core file TablePro
        // did not tag never wins over them, whatever the mirror record says.
        if taggedOutside, let legacy, mirror.isTrusted, mirror.holdsConnectionsFile {
            return importLegacy(legacy, digest: legacyDigest, into: library, over: .rebuilding, keepingCopyAs: "untrusted")
        }
        if takesLegacy(legacyDigest: legacyDigest, coreDigest: coreDigest) {
            // A change this build cannot read is never written over, as connections.json has always been kept.
            guard let legacy else {
                Self.logger.error("The previous stable's library changed and could not be read; nothing is written over it")
                return failLoad()
            }
            if taggedOutside {
                return importLegacy(legacy, digest: legacyDigest, into: library, over: .rebuilding, keepingCopyAs: "untrusted")
            }
            remember(contents)
            // An edit the previous stable's stores do not vouch for still comes in, untrusted; the file it replaces stays.
            return importLegacy(
                legacy,
                digest: legacyDigest,
                into: library,
                over: .file(coreDigest),
                keepingCopyAs: mirror.isTrusted ? nil : "replaced"
            )
        }
        var loaded = adopt(contents, verdict: verdict)
        legacyHeld = legacy?.connections.filter { heldByCore.contains($0.id) } ?? []
        if let legacy {
            loaded.favoritesOrder = keepingUnreadFavorites(of: loaded.favoritesOrder, from: legacy.favoritesOrder)
            image = loaded
        }
        // Before the mirror is written again, or it would write the profiles the core does not hold yet out of it.
        takeInProfiles(from: legacy)
        if let current = image, let digest = seenDigest {
            remirrorIfBehind(current, legacyDigest: mirror.digest(), legacyReads: legacy != nil, coreDigest: digest)
        }
        return image
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
        return importLegacy(legacy, digest: legacyDigest, into: library, over: .rebuilding)
    }

    // Bytes that do not decode. A read that failed for the system (`document_unreadable`) is not damage.
    nonisolated private static let damageCodes: Set<String> = [
        "storage.document_corrupt",
        "storage.document_missing_version",
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
        case rebuilding
    }

    private func importLegacy(
        _ legacy: LegacyLibraryMirror.Contents,
        digest: String,
        into library: ConnectionLibrary,
        over target: ImportTarget,
        keepingCopyAs reason: String? = nil
    ) -> LibraryImage? {
        // A readable file the import replaces is kept; one that does not read the core's rebuild sets aside itself.
        var copy: URL?
        if let reason, FileManager.default.fileExists(atPath: coreFileURL.path) {
            guard let made = copyCoreFile(as: reason) else { return failLoad() }
            copy = made
        }
        if case .rebuilding = target {
            forgetCoreState()
        }
        // A newer build wrote the core's copy of a connection it holds unread; the previous stable's is older.
        var imported = LibraryImage(
            connections: legacy.connections.filter { !heldByCore.contains($0.id) },
            groups: legacy.groups,
            tags: legacy.tags,
            favoritesOrder: legacy.favoritesOrder,
            projects: legacy.projects,
            sshProfiles: legacy.sshProfiles.filter { !heldProfiles.contains($0.id) },
            credentialProfiles: legacy.credentialProfiles.filter { !heldProfiles.contains($0.id) }
        ).keepingFirstOfEachId()
        imported.favoritesOrder = imported.favorites(keeping: unreadableIds)
        profilesTrusted = mirror.profilesTrusted
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
            discard(copy)
            return failLoad()
        }
        writeCount += 1
        seenDigest = written.digest
        rememberWritten(write)
        legacyHeld = legacy.connections.filter { heldByCore.contains($0.id) }
        // A file changed outside TablePro hands its verdict on; a missing tag must then read as modified, never adopted.
        settleTag(written.digest, stamping: mirror.isTrusted)
        settleProfilesSeal(imported.credentialProfiles)
        image = imported
        updateLocalOnly(imported)
        mirror.record = mirrorRecord(legacy: digest, core: written.digest)
        mirror.profilesInCore = true
        lastLoadFailed = false
        Self.logger.info("Read the connection library from connections.json into the core")
        return imported
    }

    private func adopt(_ contents: LibraryContents, verdict: ConnectionStoreIntegrity.Verdict) -> LibraryImage {
        isTrusted = verdict == .trusted
        profilesTrusted = sealVerifies(contents.credentialProfiles.map(LibraryRecordMapping.credentialProfile))
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
            favoritesOrder: contents.favorites.compactMap(UUID.init(uuidString:)),
            projects: contents.projects.map(LibraryRecordMapping.project),
            sshProfiles: contents.sshProfiles.map(LibraryRecordMapping.sshProfile),
            credentialProfiles: contents.credentialProfiles.map(LibraryRecordMapping.credentialProfile)
        )
        image = loaded
        updateLocalOnly(loaded)
        lastLoadFailed = false
        return loaded
    }

    // The core holds only the favourites it reads; the ones connections.json holds unread keep their place after the
    // favourite named before them, as the previous stable's order has them.
    private func keepingUnreadFavorites(of order: [UUID], from legacyOrder: [UUID]) -> [UUID] {
        let unread = mirror.unreadableIds
        var merged = order
        var previous: UUID?
        for id in legacyOrder {
            if unread.contains(id), !merged.contains(id) {
                let at = previous.flatMap { merged.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                merged.insert(id, at: at)
            }
            previous = id
        }
        return merged
    }

    // Before this build the profiles lived only in the previous stable's stores, so a core file an earlier build wrote
    // holds none: the first launch that finds them missing takes them in, once.
    private func takeInProfiles(from legacy: LegacyLibraryMirror.Contents?) {
        guard !mirror.profilesInCore, let legacy, let current = image else { return }
        var next = current
        let sshIds = Set(current.sshProfiles.map(\.id))
        let credentialIds = Set(current.credentialProfiles.map(\.id))
        next.sshProfiles += legacy.sshProfiles.filter { !sshIds.contains($0.id) && !heldProfiles.contains($0.id) }
        next.credentialProfiles += legacy.credentialProfiles.filter {
            !credentialIds.contains($0.id) && !heldProfiles.contains($0.id)
        }
        if next != current {
            profilesTrusted = profilesTrusted && mirror.profilesTrusted
            guard commit(next, byUser: false) else { return }
        }
        mirror.profilesInCore = true
    }

    private var profilesSealURL: URL {
        coreFileURL.deletingLastPathComponent().appendingPathComponent("connections.json.credential-profiles")
    }

    // What a profile can run: its id and its password, in the format credentialProfiles.json has always stored it.
    nonisolated private static func seal(of profiles: [CredentialProfile]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var sealed = Data()
        for profile in profiles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let mode = try? encoder.encode(profile.passwordMode) else { return nil }
            sealed.append(Data(profile.id.uuidString.utf8))
            sealed.append(mode)
        }
        return sealed
    }

    private func sealVerifies(_ profiles: [CredentialProfile]) -> Bool {
        guard !profiles.isEmpty else { return true }
        guard let sealed = Self.seal(of: profiles) else { return false }
        return integrity.verify(sealed, fileURL: profilesSealURL) == .trusted
    }

    // Seals the profiles a write left while they were vouched for; any other write leaves no seal that could vouch.
    private func settleProfilesSeal(_ profiles: [CredentialProfile]) {
        if profilesTrusted, let sealed = Self.seal(of: profiles) {
            profilesTrusted = integrity.stamp(sealed, fileURL: profilesSealURL)
            return
        }
        try? FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: profilesSealURL))
        _ = integrity.recordTagged(fileURL: profilesSealURL)
        profilesTrusted = false
    }

    // Tags the file a write left when asked. Any other write leaves no tag beside it, since an older one could still
    // match these bytes and vouch for what this write did not.
    private func settleTag(_ digest: String?, stamping: Bool) {
        if stamping {
            // No file holds nothing to vouch for; the first write tags the one it makes.
            guard let digest else {
                isTrusted = true
                return
            }
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

    // The writes the core made itself since the last look, each made over a file this store vouched for or over another
    // of them. One made over anything else, a file planted outside TablePro, never reaches the tag. Taken once: the
    // core forgets what it handed over.
    private func digestsTheCoreVouchesFor() -> Set<String> {
        let reports: [LibraryWriteReport]
        do {
            let core = try host.core()
            reports = try Self.blocking { try await core.takeLibraryWrites() }
        } catch {
            Self.logger.error("The core's own library writes could not be read: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return []
        }
        var vouched: Set<String> = []
        for report in reports {
            guard let over = report.over else { continue }
            if vouched.contains(over) || integrity.verify(Self.tag(forDigest: over), fileURL: coreFileURL) == .trusted {
                vouched.insert(report.digest)
            }
        }
        return vouched
    }

    nonisolated private static func code(of error: any Error) -> String? {
        guard case CoreError.Failed(let info) = error else { return nil }
        return info.code
    }

    private func holdsNewerFile(_ library: ConnectionLibrary) -> Bool {
        do {
            _ = try Self.blocking { try await library.libraryContents() }
            return false
        } catch {
            return Self.code(of: error).map { !Self.damageCodes.contains($0) } ?? true
        }
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

    // This store's copies, the files the core set aside as unreadable, and its copies from before an upgrade.
    nonisolated private static func keptCopy(_ suffix: String) -> Bool {
        ["untrusted-", "replaced-", "corrupt-"].contains(where: suffix.hasPrefix)
            || suffix.range(of: #"^v[0-9]+-[0-9]+(-[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private func removeSetAsideCopies(keeping kept: URL? = nil) -> Bool {
        let folder = coreFileURL.deletingLastPathComponent()
        let prefix = "\(coreFileURL.lastPathComponent)."
        do {
            let copies = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { url in
                    let name = url.lastPathComponent
                    guard name != kept?.lastPathComponent else { return false }
                    if name.hasPrefix(".\(prefix)v"), name.hasSuffix(".partial") {
                        return true
                    }
                    return name.hasPrefix(prefix) && Self.keptCopy(String(name.dropFirst(prefix.count)))
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
        storedProjects = [:]
        storedSSHProfiles = [:]
        heldProfiles = []
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
        profilesTrusted = false
        image = nil
        return nil
    }

    // MARK: - State

    private func remember(_ contents: LibraryContents) {
        remember(
            connections: contents.connections,
            groups: contents.groups,
            tags: contents.tags,
            projects: contents.projects,
            sshProfiles: contents.sshProfiles
        )
        heldByCore = Set(contents.unreadable.compactMap(UUID.init(uuidString:)))
        heldProfiles = Set(contents.unreadableProfiles.compactMap(UUID.init(uuidString:)))
    }

    // The core holds what the write named, and the entries it held that the write did not take out.
    private func rememberWritten(_ write: LibraryWriteRecord) {
        remember(
            connections: write.connections,
            groups: write.groups,
            tags: write.tags,
            projects: write.projects,
            sshProfiles: write.sshProfiles
        )
        let removed = write.removing.compactMap(UUID.init(uuidString:))
        heldByCore.subtract(removed)
        heldProfiles.subtract(removed)
    }

    private func remember(
        connections: [LibraryConnectionRecord],
        groups: [GroupRecord],
        tags: [TagRecord],
        projects: [ProjectRecord],
        sshProfiles: [SshProfileRecord]
    ) {
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
        storedProjects = Dictionary(
            projects.compactMap { record in UUID(uuidString: record.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
        storedSSHProfiles = Dictionary(
            sshProfiles.compactMap { record in UUID(uuidString: record.id).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func updateLocalOnly(_ image: LibraryImage) {
        localOnly.set(Set(image.connections.filter { !$0.participatesInSync }.map(\.id)))
        profileSecrets.remember(image.credentialProfiles)
    }

    private func records(for image: LibraryImage, removing: Set<UUID>) -> LibraryWriteRecord {
        LibraryWriteRecord(
            connections: image.connections.map { LibraryRecordMapping.record($0, keeping: stored[$0.id]) },
            groups: image.groups.map { LibraryRecordMapping.record($0, keeping: storedGroups[$0.id]) },
            tags: image.tags.map { LibraryRecordMapping.record($0, keeping: storedTags[$0.id]) },
            // The core keeps only the favourites it holds; connections.json's unread ones stay in the mirror's order.
            favorites: image.favorites(keeping: heldByCore).map(\.uuidString),
            projects: image.projects.map { LibraryRecordMapping.record($0, keeping: storedProjects[$0.id]) },
            sshProfiles: image.sshProfiles.map { LibraryRecordMapping.record($0, keeping: storedSSHProfiles[$0.id]) },
            credentialProfiles: image.credentialProfiles.map(LibraryRecordMapping.record),
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
            connections: image.connections + legacyHeld.filter { heldByCore.contains($0.id) },
            groups: image.groups,
            tags: image.tags,
            favoritesOrder: image.favoritesOrder,
            projects: image.projects,
            sshProfiles: image.sshProfiles,
            credentialProfiles: image.credentialProfiles
        )
        // Recorded first, so a launch after a crash here knows these stores are behind the core's.
        mirror.record = mirrorRecord(legacy: mirror.digest(), core: coreDigest, legacyBehind: true)
        // The copy vouches for no more than the store it copies.
        if !isTrusted {
            mirror.file.withdrawTrust()
        }
        if !profilesTrusted {
            mirror.profilesFile.withdrawTrust()
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
