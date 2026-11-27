import Foundation
import os
import TableProConnectionLibrary
import TableProLogRedaction

// One list file of the library. Each save leaves a copy of what it wrote as `<file>.backup`, and a file that no
// longer parses is restored from it, the damaged copy kept as `<file>.unreadable`.
final class LibraryFile<Element: Codable> {
    private static var logger: Logger { Logger(subsystem: "com.TablePro", category: "LibraryFile") }
    private static var writeOptions: Data.WritingOptions { [.atomic, .completeFileProtectionUntilFirstUserAuthentication] }

    let fileURL: URL
    private let label: String
    // Records the last load could not decode; every save writes them back after the decoded ones.
    private var unreadable: [UnreadableLibraryRecord] = []
    // Set by a save that takes secrets out until the old copies are gone, so a later save cannot leave them behind.
    private var backupHoldsRemovedSecrets = false

    var backupURL: URL { fileURL.appendingPathExtension("backup") }
    var unreadableURL: URL { fileURL.appendingPathExtension("unreadable") }
    var unreadableIds: Set<UUID> { Set(unreadable.compactMap(\.id)) }
    var holdsUnreadableRecords: Bool { !unreadable.isEmpty }

    init(directory: URL, name: String) {
        fileURL = directory.appendingPathComponent(name)
        label = name
    }

    // Nil when there is no file. A read error, such as a device locked since restart, throws and never restores.
    func load(using decoder: JSONDecoder = JSONDecoder()) throws -> (elements: [Element], data: Data)? {
        unreadable = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var data = try Data(contentsOf: fileURL)
        let records: LibraryFileRecords<Element>
        do {
            records = try LibraryFileRecords(decoding: data, using: decoder)
        } catch {
            guard let backup = restoreBackup(over: data) else { throw error }
            data = backup
            records = try LibraryFileRecords(decoding: backup, using: decoder)
        }
        unreadable = records.unreadable
        if !unreadable.isEmpty {
            Self.logger.error(
                "\(self.label, privacy: .public) holds \(self.unreadable.count, privacy: .public) records this build cannot read; they are kept as they are"
            )
        }
        return (records.elements, data)
    }

    // `finishing` rewrites the encoded list before it is written, as the pasted SSH key migration does.
    // `removingUnreadable` drops kept records by id, as a deletion another device made does.
    // `willWrite` sees the bytes just before they replace the file.
    func save(
        _ elements: [Element],
        using encoder: JSONEncoder = JSONEncoder(),
        removingSecrets: Bool = false,
        removingUnreadable removedIds: Set<UUID> = [],
        willWrite: (Data) -> Void = { _ in },
        finishing finish: (Data) throws -> Data = { $0 }
    ) throws {
        if removingSecrets {
            backupHoldsRemovedSecrets = true
        }
        let encoded = try LibraryFileRecords.encoded(elements, keeping: unreadable, removing: removedIds, using: encoder)
        let data = try finish(encoded.data)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The backup and a damaged copy still hold the secrets taken out; a save that cannot drop them writes nothing.
        if backupHoldsRemovedSecrets {
            try removeIfPresent(backupURL)
            try removeIfPresent(unreadableURL)
            backupHoldsRemovedSecrets = false
        }
        willWrite(data)
        try data.write(to: fileURL, options: Self.writeOptions)
        unreadable = encoded.kept
        mirrorToBackup(data)
    }

    private func restoreBackup(over damaged: Data) -> Data? {
        guard let backup = try? Data(contentsOf: backupURL), LibraryFileRecords<Element>.isList(backup) else { return nil }
        do {
            try damaged.write(to: unreadableURL, options: Self.writeOptions)
            try backup.write(to: fileURL, options: Self.writeOptions)
        } catch {
            Self.logger.error(
                "Could not restore \(self.label, privacy: .public) from its backup: \(LogRedaction.publicDescription(of: error), privacy: .public)"
            )
            return nil
        }
        Self.logger.warning(
            "Restored \(self.label, privacy: .public) from its backup; the damaged file is kept beside it"
        )
        return backup
    }

    // The backup is the file as last saved, so a restore loses no save. A copy that cannot be made leaves no older
    // one behind.
    private func mirrorToBackup(_ data: Data) {
        do {
            try data.write(to: backupURL, options: Self.writeOptions)
        } catch {
            Self.logger.error(
                "Could not keep a backup of \(self.label, privacy: .public): \(LogRedaction.publicDescription(of: error), privacy: .public)"
            )
            try? removeIfPresent(backupURL)
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
