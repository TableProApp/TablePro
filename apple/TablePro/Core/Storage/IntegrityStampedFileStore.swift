//
//  IntegrityStampedFileStore.swift
//  TablePro
//

import Foundation
import os
import TableProConnectionLibrary

// A list in a file that says whether TablePro last wrote it: a connection or credential profile can declare a shell
// command the app runs at connect time, and the file is ordinary user-writable storage.
@MainActor
final class IntegrityStampedFileStore<Element: Codable> {
    // False until a load answers, so a caller that reads it first never gets "trusted" for an unverified file.
    private(set) var isTrusted = false

    let fileURL: URL

    private let label: String
    private let logger: Logger
    private let integrity: ConnectionStoreIntegrity
    private let userSaveEstablishesTrust: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    // Records the last load could not decode; every save writes them back after the decoded ones.
    private var preserved: [UnreadableLibraryRecord] = []
    // Unreadable records of an untrusted file that could not be set aside: kept, so a save writes but never signs them.
    private var holdsUnverifiedRecords = false

    var unreadableIds: Set<UUID> { Set(preserved.compactMap(\.id)) }

    var backupURL: URL { fileURL.appendingPathExtension("backup") }
    var unreadableURL: URL { fileURL.appendingPathExtension("unreadable") }
    var unreadableRecordsURL: URL { fileURL.appendingPathExtension("unreadable-records") }

    // `userSaveEstablishesTrust`: connections.json predates the tag and re-saving clears a tamper flag, so yes;
    // credentialProfiles.json re-signs every entry on any save, which would bless a planted command, so no.
    init(
        fileURL: URL,
        label: String,
        logger: Logger,
        userSaveEstablishesTrust: Bool,
        integrity: ConnectionStoreIntegrity = .shared
    ) {
        self.fileURL = fileURL
        self.label = label
        self.logger = logger
        self.userSaveEstablishesTrust = userSaveEstablishesTrust
        self.integrity = integrity
    }

    // Only an absent file is an empty list, a fresh install; one that cannot be read, or parsed with no backup, is nil, never saved over.
    func load() -> [Element]? {
        preserved = []
        holdsUnverifiedRecords = false
        var data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            isTrusted = true
            return []
        } catch {
            logger.error("Failed to read \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)")
            isTrusted = false
            return nil
        }

        var records: LibraryFileRecords<Element>?
        var restoredWithoutTag = false
        do {
            records = try LibraryFileRecords(decoding: data, using: decoder)
        } catch {
            logger.error("Failed to decode \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)")
            if let restored = restoreBackup(over: data) {
                data = restored.data
                restoredWithoutTag = !restored.hasTag
                records = try? LibraryFileRecords(decoding: data, using: decoder)
            }
        }

        adoptVerdict(for: data, restoredWithoutTag: restoredWithoutTag)

        guard let records else { return nil }
        preserved = records.unreadable
        if !preserved.isEmpty {
            logger.error(
                "\(self.label, privacy: .public) holds \(self.preserved.count, privacy: .public) records this build cannot read; they are kept as they are"
            )
        }
        // A save signs the whole file, and the user never saw these records, so an untrusted file's go beside it instead.
        if !isTrusted, !preserved.isEmpty {
            if setAside(preserved) {
                preserved = []
            } else {
                holdsUnverifiedRecords = true
            }
        }
        return records.elements
    }

    // False when nothing reached disk, so a caller writing keychain items or tombstones aborts. `byUser` false is a
    // write nobody asked for, such as a sync pull, which is not consent either. `removingUnreadable` drops kept
    // records by id, as a deletion another device made does.
    @discardableResult
    func save(
        _ elements: [Element],
        byUser: Bool = true,
        removingSecrets: Bool = false,
        removingUnreadable removedIds: Set<UUID> = []
    ) -> Bool {
        let encoded: (data: Data, kept: [UnreadableLibraryRecord])
        do {
            encoded = try LibraryFileRecords.encoded(elements, keeping: preserved, removing: removedIds, using: encoder)
            // The backup and a damaged copy still hold the secrets this save takes out; a save that cannot drop them
            // writes nothing.
            if removingSecrets {
                try removeBackup()
                try removeIfPresent(unreadableURL)
            }
            try encoded.data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return false
        }
        preserved = encoded.kept
        if preserved.isEmpty {
            holdsUnverifiedRecords = false
        }
        // A store that does not take a save as consent keeps the verdict its last load reached.
        if (userSaveEstablishesTrust && byUser) || isTrusted, !holdsUnverifiedRecords {
            // With no tag written, later edits are undetectable, so the file is not trusted.
            isTrusted = integrity.stamp(encoded.data, fileURL: fileURL)
        } else {
            logger.warning("Saved \(self.label, privacy: .public) without a trust tag; it stays untrusted")
        }
        mirrorToBackup(encoded.data)
        return true
    }

    private func adoptVerdict(for data: Data, restoredWithoutTag: Bool) {
        var verdict = integrity.verify(data, fileURL: fileURL)
        // A restored backup that carried no tag is not a store from before the tag existed.
        if restoredWithoutTag, verdict == .unstamped {
            verdict = .modified
        }

        switch verdict {
        case .trusted:
            isTrusted = true
        case .unstamped:
            guard userSaveEstablishesTrust else {
                logger.warning("\(self.label, privacy: .public) has no integrity tag; anything it declares will not run")
                isTrusted = false
                return
            }
            // Never tagged on this device: adopt the file as it stands, the only baseline there is.
            integrity.stamp(data, fileURL: fileURL)
            isTrusted = true
        case .modified:
            logger.warning("\(self.label, privacy: .public) changed outside TablePro; anything it declares will not run")
            isTrusted = false
        case .unavailable:
            logger.warning("No integrity key for \(self.label, privacy: .public); anything it declares will not run")
            isTrusted = false
        }
    }

    // Each step leaves either the damaged file in place, so the next load retries, or the backup with its own tag.
    private func restoreBackup(over damaged: Data) -> (data: Data, hasTag: Bool)? {
        guard let backup = try? Data(contentsOf: backupURL), LibraryFileRecords<Element>.isList(backup) else { return nil }
        let backupTag = try? Data(contentsOf: ConnectionStoreIntegrity.tagURL(for: backupURL))
        let hasTag = backupTag?.isEmpty == false
        let tagURL = ConnectionStoreIntegrity.tagURL(for: fileURL)
        do {
            try damaged.write(to: unreadableURL, options: .atomic)
            if let backupTag, hasTag {
                try backupTag.write(to: tagURL, options: .atomic)
            } else {
                try removeIfPresent(tagURL)
                // Remembered as tagged, so the next load reads the missing tag as modified and never adopts these bytes.
                guard integrity.recordTagged(fileURL: fileURL) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try backup.write(to: fileURL, options: .atomic)
        } catch {
            logger.error(
                "Could not restore \(self.label, privacy: .public) from its backup: \(error.publicLogShape, privacy: .public)"
            )
            return nil
        }
        logger.warning(
            "Restored \(self.label, privacy: .public) from its backup; the damaged file is kept as \(self.label, privacy: .public).unreadable"
        )
        return (backup, hasTag)
    }

    // The backup is the file as last saved, with its tag, so a restore loses no save. A copy that cannot be made
    // leaves no older one behind.
    private func mirrorToBackup(_ data: Data) {
        let tag = try? Data(contentsOf: ConnectionStoreIntegrity.tagURL(for: fileURL))
        let backupTagURL = ConnectionStoreIntegrity.tagURL(for: backupURL)
        do {
            try data.write(to: backupURL, options: .atomic)
            if let tag {
                try tag.write(to: backupTagURL, options: .atomic)
            } else {
                try removeIfPresent(backupTagURL)
            }
        } catch {
            logger.error(
                "Could not keep a backup of \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            try? removeBackup()
        }
    }

    private func removeBackup() throws {
        try removeIfPresent(backupURL)
        try removeIfPresent(ConnectionStoreIntegrity.tagURL(for: backupURL))
    }

    // Added to what an earlier load set aside, so a file loaded again before its next save adds nothing twice.
    private func setAside(_ records: [UnreadableLibraryRecord]) -> Bool {
        var kept = (try? Data(contentsOf: unreadableRecordsURL))
            .flatMap { try? decoder.decode([UnreadableLibraryRecord].self, from: $0) } ?? []
        for record in records where !kept.contains(record) {
            kept.append(record)
        }
        do {
            try encoder.encode(kept).write(to: unreadableRecordsURL, options: .atomic)
            return true
        } catch {
            logger.error(
                "Could not set aside unreadable records of \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            return false
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
