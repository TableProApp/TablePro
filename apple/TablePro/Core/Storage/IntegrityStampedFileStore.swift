//
//  IntegrityStampedFileStore.swift
//  TablePro
//

import Foundation
import os

/// A `Codable` list in a file that can say whether TablePro is the last thing that wrote it.
///
/// `connections.json` needs that answer because a connection can declare a `PasswordSource` whose
/// shell command the app runs at connect time, and the file is ordinary user-writable storage. A
/// credential profile can declare the same thing, so it needs the same answer rather than a second
/// hand-written copy of the read-verify-adopt and write-stamp cycle.
///
/// The load is deliberately three-valued. A file that will not decode is not an empty list: saving
/// over it would destroy whatever it held, which is why every caller has to tell the two apart.
@MainActor
final class IntegrityStampedFileStore<Element: Codable> {
    /// Whether the file on disk is the one TablePro last wrote. False once something else has
    /// edited it, which is the signal to refuse to run anything it declares.
    ///
    /// False until a load has answered. Starting at true meant a caller that read the flag before
    /// reading the file got "trusted" for a file nothing had verified.
    private(set) var isTrusted = false

    let fileURL: URL

    private let label: String
    private let logger: Logger
    private let integrity: ConnectionStoreIntegrity
    private let userSaveEstablishesTrust: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    // Records the last load could not decode; every save writes them back after the decoded ones.
    private var preserved: [PreservedJSON] = []
    // Unreadable records of an untrusted file that could not be set aside: kept, so a save writes but never signs them.
    private var holdsUnverifiedRecords = false

    var backupURL: URL { fileURL.appendingPathExtension("backup") }
    var unreadableURL: URL { fileURL.appendingPathExtension("unreadable") }
    var unreadableRecordsURL: URL { fileURL.appendingPathExtension("unreadable-records") }

    /// `userSaveEstablishesTrust` says whether writing this file is itself the user's consent to
    /// trust what is in it.
    ///
    /// `connections.json` says yes, and that is deliberate: it predates the tag, so an untagged one
    /// is an ordinary upgrade, and re-saving a connection in the app is the documented way to clear
    /// a tamper flag. `credentialProfiles.json` says no. It has no untagged history, and its writes
    /// are read-modify-write over the whole list, so saving any profile would re-sign every other
    /// entry in the file. That is how a planted `.command(shell:)` would get blessed by a user who
    /// only renamed something.
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

        var entries: [StoredEntry<Element>]?
        var restoredWithoutTag = false
        do {
            entries = try decoder.decode([StoredEntry<Element>].self, from: data)
        } catch {
            logger.error("Failed to decode \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)")
            if let restored = restoreBackup(over: data) {
                data = restored.data
                restoredWithoutTag = !restored.hasTag
                entries = try? decoder.decode([StoredEntry<Element>].self, from: data)
            }
        }

        adoptVerdict(for: data, restoredWithoutTag: restoredWithoutTag)

        guard let entries else { return nil }
        var elements: [Element] = []
        for entry in entries {
            switch entry {
            case .decoded(let element):
                elements.append(element)
            case .preserved(let json):
                preserved.append(json)
            }
        }
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
        return elements
    }

    /// False when nothing reached disk. A caller that also writes keychain items or sync tombstones
    /// has to abort on that rather than strand them against a record that was never persisted.
    /// `byUser` false is a write nobody asked for, such as a sync pull, which is not consent either.
    @discardableResult
    func save(_ elements: [Element], byUser: Bool = true) -> Bool {
        do {
            let entries = elements.map(StoredEntry<Element>.decoded) + preserved.map(StoredEntry<Element>.preserved)
            let data = try encoder.encode(entries)
            keepBackup()
            try data.write(to: fileURL, options: .atomic)
            // A store that does not take a save as consent keeps the verdict its last load reached.
            guard (userSaveEstablishesTrust && byUser) || isTrusted, !holdsUnverifiedRecords else {
                logger.warning("Saved \(self.label, privacy: .public) without a trust tag; it stays untrusted")
                return true
            }
            // With no tag written, later edits are undetectable, so the file is not trusted.
            isTrusted = integrity.stamp(data, fileURL: fileURL)
            return true
        } catch {
            logger.error("Failed to save \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return false
        }
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
        guard let backup = try? Data(contentsOf: backupURL), parsesAsArray(backup) else { return nil }
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

    // A file that no longer parses never replaces the last good copy.
    private func keepBackup() {
        guard let current = try? Data(contentsOf: fileURL), parsesAsArray(current) else { return }
        let tag = try? Data(contentsOf: ConnectionStoreIntegrity.tagURL(for: fileURL))
        let backupTagURL = ConnectionStoreIntegrity.tagURL(for: backupURL)
        do {
            try current.write(to: backupURL, options: .atomic)
            if let tag {
                try tag.write(to: backupTagURL, options: .atomic)
            } else {
                try removeIfPresent(backupTagURL)
            }
        } catch {
            logger.error(
                "Could not keep a backup of \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
        }
    }

    // Added to what an earlier load set aside, so a file loaded again before its next save adds nothing twice.
    private func setAside(_ records: [PreservedJSON]) -> Bool {
        var kept = (try? Data(contentsOf: unreadableRecordsURL)).flatMap { try? decoder.decode([PreservedJSON].self, from: $0) } ?? []
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

    // The same check load makes, so a restored backup always loads.
    private func parsesAsArray(_ data: Data) -> Bool {
        (try? decoder.decode([PreservedJSON].self, from: data)) != nil
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}

private enum StoredEntry<Element: Codable>: Codable {
    case decoded(Element)
    case preserved(PreservedJSON)

    init(from decoder: any Decoder) throws {
        if let element = try? Element(from: decoder) {
            self = .decoded(element)
        } else {
            self = .preserved(try PreservedJSON(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .decoded(let element):
            try element.encode(to: encoder)
        case .preserved(let json):
            try json.encode(to: encoder)
        }
    }
}

// Integers decode before doubles so ids and ports keep their precision.
private enum PreservedJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([PreservedJSON])
    case object([String: PreservedJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PreservedJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PreservedJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
