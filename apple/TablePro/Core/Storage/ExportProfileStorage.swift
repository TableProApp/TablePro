//
//  ExportProfileStorage.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Format options and the last format persist elsewhere; this keeps the selection a user would rebuild by hand.
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

        // Keyed by kind as well as name, because a routine and a table can share one.
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

// Device-local: a profile names tables on one server, which the other Mac's connection may not have.
@MainActor
final class ExportProfileStorage {
    static let shared = ExportProfileStorage()

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

    // Saving under a name that already exists replaces it, so the picker never shows one label twice.
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

    // A gone object stays gone and an unnamed one is deselected, so applying a profile twice gives the same selection.
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

    // Lets the picker say a profile has gone stale instead of silently selecting fewer rows than it names.
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

    private func file(for connectionId: UUID) -> JSONFileStore<[ExportProfile]> {
        JSONFileStore(url: directory.appendingPathComponent("\(connectionId.uuidString).json"))
    }

    private func load(_ connectionId: UUID) -> [ExportProfile] {
        file(for: connectionId).read().value ?? []
    }

    private func persist(_ profiles: [ExportProfile], for connectionId: UUID) {
        cache[connectionId] = profiles
        let store = file(for: connectionId)
        guard !profiles.isEmpty else {
            try? store.remove()
            return
        }
        try? store.write(profiles)
    }
}
