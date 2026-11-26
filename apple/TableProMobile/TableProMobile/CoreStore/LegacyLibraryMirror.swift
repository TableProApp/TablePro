import CryptoKit
import Foundation
import os
import TableProModels

// The library in the files the previous stable reads: connections.json, groups.json and tags.json. The core holds the
// library; these stay in step with it until that build runs the core (core ADR 0054, Downgrade mirror). An App Store
// build installed over a TestFlight one keeps the app's data, so iOS has a path back too.
@MainActor
final class LegacyLibraryMirror {
    struct Contents {
        var connections: [DatabaseConnection]
        var groups: [ConnectionGroup]
        var tags: [ConnectionTag]
        var pastedSSHKeys: [UUID: String]
    }

    // What the last complete write left on each side, so a launch can tell which side another build changed.
    struct Record: Codable, Equatable {
        var legacy: String
        var core: String
        // The core's store took a write these files did not, so the next launch writes them again.
        var legacyBehind: Bool
    }

    static let recordKey = "com.TablePro.library.mirrorRecord"
    static let fileNames = ["connections.json", "groups.json", "tags.json"]

    private static let logger = Logger(subsystem: "com.TablePro", category: "LegacyLibraryMirror")

    private let directory: URL
    private let defaults: UserDefaults
    private let connectionFile: ConnectionPersistence
    private let groupFile: GroupPersistence
    private let tagFile: TagPersistence

    init(directory: URL, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
        connectionFile = ConnectionPersistence(directory: directory)
        groupFile = GroupPersistence(directory: directory)
        tagFile = TagPersistence(directory: directory)
    }

    var record: Record? {
        get { defaults.data(forKey: Self.recordKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.recordKey)
            } else {
                defaults.removeObject(forKey: Self.recordKey)
            }
        }
    }

    // Records the files hold that this build cannot read. A write keeps them only after a read found them.
    var unreadable: UnreadableCopies {
        UnreadableCopies(
            connections: connectionFile.unreadableIds,
            groups: groupFile.unreadableIds,
            tags: tagFile.unreadableIds
        )
    }

    // Throws when a file cannot be read, such as on a device locked since restart, or no longer parses and has no
    // backup. A file that no longer parses comes back from its backup, as it always has.
    func read() throws -> Contents {
        let stored = try connectionFile.load()
        return Contents(
            connections: stored.connections,
            groups: try groupFile.load(),
            tags: try tagFile.load(),
            pastedSSHKeys: stored.pastedSSHKeys
        )
    }

    // `wroteFile` runs after each file lands, so a record can name the files a write left half done.
    func write(
        _ contents: Contents,
        removingSecrets: Bool,
        removingUnreadable removed: UnreadableCopies,
        wroteFile: () -> Void
    ) throws {
        let held = unreadable
        try connectionFile.save(
            contents.connections,
            keepingPastedSSHKeys: contents.pastedSSHKeys,
            removingSecrets: removingSecrets,
            removingUnreadable: removed.connections.intersection(held.connections)
        )
        wroteFile()
        try groupFile.save(contents.groups, removingUnreadable: removed.groups.intersection(held.groups))
        wroteFile()
        try tagFile.save(contents.tags, removingUnreadable: removed.tags.intersection(held.tags))
    }

    // The copies a write that takes secrets out must not leave: the last save and the damaged file set aside.
    func removeSecretCopies() throws {
        for name in ["connections.json.backup", "connections.json.unreadable"] {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
    }

    // Of the files as they are now. A file that is absent reads differently from an empty one.
    func digest() -> String {
        var hasher = SHA256()
        for name in Self.fileNames {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                hasher.update(data: Data([0]))
                continue
            }
            hasher.update(data: Data([1]) + withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) })
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func logBehind(_ error: any Error) {
        Self.logger.error(
            "The previous stable's library files were not updated; the core's store has this write: \(error.localizedDescription, privacy: .private)"
        )
    }
}
