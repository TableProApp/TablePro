//
//  ExportProfileStorage.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// One saved export: the format, and which objects it covered with how each was narrowed.
///
/// The format's own options already persist globally through `SettablePlugin`, and the last format
/// through `TransferDialogStorage`. What neither carries is the selection, which is the part a user
/// rebuilds by hand every time: forty tables ticked, three of them filtered, two limited.
struct ExportProfile: Codable, Identifiable, Equatable {
    struct Entry: Codable, Equatable {
        let container: String
        let name: String
        let kind: String
        let optionValues: [Bool]
        let rowScope: PluginExportRowScope

        init(
            container: String,
            name: String,
            kind: PluginExportObjectKind,
            optionValues: [Bool],
            rowScope: PluginExportRowScope
        ) {
            self.container = container
            self.name = name
            self.kind = kind.rawValue
            self.optionValues = optionValues
            self.rowScope = rowScope
        }

        /// Matches the row it was saved from. Keyed by kind as well as name, because a routine and
        /// a table can share one.
        var key: String { "\(container).\(kind).\(name)" }
    }

    let id: UUID
    var name: String
    var formatId: String
    var entries: [Entry]

    init(id: UUID = UUID(), name: String, formatId: String, entries: [Entry]) {
        self.id = id
        self.name = name
        self.formatId = formatId
        self.entries = entries
    }

    var entriesByKey: [String: Entry] {
        Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }
}

/// Saved export profiles, one file per connection.
///
/// Device-local: a profile names tables on one server, and syncing it would offer a selection whose
/// objects the other Mac's connection may not have.
@MainActor
final class ExportProfileStorage {
    static let shared = ExportProfileStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportProfileStorage")

    private let directory: URL
    private var cache: [UUID: [ExportProfile]] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private static func defaultDirectory() -> URL {
        AppStorageEnvironment.shared.supportDirectory
            .appendingPathComponent("ExportProfiles", isDirectory: true)
    }

    func profiles(for connectionId: UUID) -> [ExportProfile] {
        if let cached = cache[connectionId] { return cached }
        let loaded = load(connectionId)
        cache[connectionId] = loaded
        return loaded
    }

    /// Saving under a name that already exists replaces it, so re-saving a profile the user is
    /// working on does not leave two rows with the same label in the picker.
    func save(_ profile: ExportProfile, for connectionId: UUID) {
        var profiles = profiles(for: connectionId)
        if let index = profiles.firstIndex(where: { $0.name == profile.name }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist(profiles, for: connectionId)
    }

    func delete(id: UUID, for connectionId: UUID) {
        let profiles = profiles(for: connectionId).filter { $0.id != id }
        persist(profiles, for: connectionId)
    }

    func clear(for connectionId: UUID) {
        persist([], for: connectionId)
    }

    // MARK: - Building and applying

    nonisolated static func makeProfile(
        name: String,
        formatId: String,
        databases: [ExportDatabaseItem]
    ) -> ExportProfile {
        let entries = databases.flatMap { database in
            database.objects.filter(\.isSelected).map { object in
                ExportProfile.Entry(
                    container: database.name,
                    name: object.name,
                    kind: object.kind,
                    optionValues: object.optionValues,
                    rowScope: object.rowScope
                )
            }
        }
        return ExportProfile(name: name, formatId: formatId, entries: entries)
    }

    /// Applies a profile over the tree the dialog is showing. An object the profile names that the
    /// database no longer has is dropped rather than resurrected, and one the profile does not name
    /// is deselected, so applying a profile twice gives the same selection both times.
    nonisolated static func apply(_ profile: ExportProfile, to databases: [ExportDatabaseItem]) -> [ExportDatabaseItem] {
        let entries = profile.entriesByKey
        return databases.map { database in
            var updated = database
            updated.objects = database.objects.map { object in
                var applied = object
                let key = ExportProfile.Entry(
                    container: database.name,
                    name: object.name,
                    kind: object.kind,
                    optionValues: [],
                    rowScope: .unrestricted
                ).key
                guard let entry = entries[key] else {
                    applied.isSelected = false
                    return applied
                }
                applied.isSelected = true
                applied.optionValues = entry.optionValues
                applied.rowScope = entry.rowScope
                return applied
            }
            return updated
        }
    }

    /// How many of a profile's objects the current tree still holds, so the picker can say when a
    /// profile has gone stale instead of silently selecting fewer rows than it names.
    nonisolated static func matchCount(_ profile: ExportProfile, in databases: [ExportDatabaseItem]) -> Int {
        let present = Set(databases.flatMap { database in
            database.objects.map { object in
                ExportProfile.Entry(
                    container: database.name,
                    name: object.name,
                    kind: object.kind,
                    optionValues: [],
                    rowScope: .unrestricted
                ).key
            }
        })
        return profile.entries.count { present.contains($0.key) }
    }

    // MARK: - Persistence

    private func fileURL(for connectionId: UUID) -> URL {
        directory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private func load(_ connectionId: UUID) -> [ExportProfile] {
        let url = fileURL(for: connectionId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([ExportProfile].self, from: data)
        } catch {
            Self.logger.warning("Failed to read export profiles: \(error.localizedDescription)")
            return []
        }
    }

    private func persist(_ profiles: [ExportProfile], for connectionId: UUID) {
        cache[connectionId] = profiles
        let url = fileURL(for: connectionId)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            guard !profiles.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.warning("Failed to write export profiles: \(error.localizedDescription)")
        }
    }
}
