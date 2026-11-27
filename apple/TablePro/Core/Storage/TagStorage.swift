//
//  TagStorage.swift
//  TablePro
//
//  Created by Claude on 20/12/25.
//

import Combine
import Foundation
import os
import TableProConnectionLibrary
import TableProImport
import TableProSyncTransport

internal enum TagStorageError: LocalizedError, Equatable {
    case duplicateName(String)
    case storeUnreadable

    internal var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return String(format: String(localized: "A tag named “%@” already exists."), name)
        case .storeUnreadable:
            return String(localized: "The saved tags could not be read. Nothing was changed.")
        }
    }
}

@MainActor
internal final class TagStorage {
    internal static let shared = TagStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TagStorage")

    private let tagsKey = "com.TablePro.tags"
    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let appEvents: AppEvents
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedTags: [ConnectionTag]?
    // Records this build cannot read. Every write puts them back as they were read.
    private var preserved: [UnreadableLibraryRecord] = []
    // Every write replaces the whole list, so a payload that could not be read is never written over with the
    // presets shown in its place.
    internal private(set) var storeIsUnreadable = false

    internal init(
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        syncTracker: SyncChangeTracker = .shared,
        appEvents: AppEvents = .shared
    ) {
        self.defaults = userDefaults
        self.syncTracker = syncTracker
        self.appEvents = appEvents
        if loadTags().isEmpty {
            saveTags(ConnectionTag.presets)
        }
    }

    // MARK: - Tag CRUD

    // An entry that does not decode is kept as it was read, and the rest of the list loads.
    internal func loadTags() -> [ConnectionTag] {
        if let cached = cachedTags { return cached }

        guard let data = defaults.data(forKey: tagsKey) else {
            storeIsUnreadable = false
            preserved = []
            let tags = ConnectionTag.presets
            cachedTags = tags
            return tags
        }

        guard let records = try? LibraryFileRecords<ConnectionTag>(decoding: data, using: decoder) else {
            Self.logger.error("Tag store could not be read; leaving it untouched")
            storeIsUnreadable = true
            preserved = []
            return ConnectionTag.presets
        }

        if !records.unreadable.isEmpty {
            Self.logger.error("Kept \(records.unreadable.count, privacy: .public) tag entries this build cannot read")
        }
        storeIsUnreadable = false
        preserved = records.unreadable
        cachedTags = records.elements
        return records.elements
    }

    // Loads first, so the answer does not depend on whether anything has read the store yet.
    internal var unreadableTagIds: Set<UUID> {
        _ = loadTags()
        return Set(preserved.compactMap(\.id))
    }

    // False leaves the store holding the previous set. A save carrying the id of a record this build cannot read
    // is refused. `removingUnreadable` drops such records by id, as a deletion another device made does.
    @discardableResult
    internal func saveTags(
        _ tags: [ConnectionTag],
        removingUnreadable removedIds: Set<UUID> = []
    ) -> Bool {
        let loaded = loadTags()
        // With nothing stored, what loaded is the presets shown in its place, which were never saved.
        let previous = defaults.data(forKey: tagsKey) == nil ? [] : loaded
        guard !storeIsUnreadable else {
            Self.logger.error("Refusing to overwrite an unreadable tag store")
            return false
        }

        do {
            let encoded = try LibraryFileRecords.encoded(
                tags, keeping: preserved, removing: removedIds, using: encoder
            )
            defaults.set(encoded.data, forKey: tagsKey)
            preserved = encoded.kept
            cachedTags = nil
            syncTracker.markDirty(.tag, ids: SyncRecordChanges.changedIds(from: previous, to: tags))
            return true
        } catch {
            Self.logger.error("Failed to save tags: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }

    internal func addTag(_ tag: ConnectionTag) throws {
        var tags = loadTags()
        guard !tags.contains(where: { $0.name.lowercased() == tag.name.lowercased() }) else {
            throw TagStorageError.duplicateName(tag.name)
        }

        tags.append(tag)
        guard saveTags(tags) else { throw TagStorageError.storeUnreadable }
        notifyChanged()
    }

    /// Apply a tag that arrived from another device.
    ///
    /// Written as it arrived, and skipped when it matches what is already stored.
    @discardableResult
    internal func applyRemoteTag(_ tag: ConnectionTag) -> RemoteApplyOutcome {
        var tags = loadTags()

        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            guard tags[index] != tag else { return .skipped }
            tags[index] = tag
        } else {
            tags.append(tag)
        }

        return saveTags(tags) ? .applied : .failed
    }

    // A deletion another device made: no tombstone and no notification, which the pull raises once. A tag always
    // syncs, so one this build cannot read goes by its id.
    @discardableResult
    internal func applyRemoteDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        var tags = loadTags()
        guard !storeIsUnreadable else { return false }
        tags.removeAll { ids.contains($0.id) }
        return saveTags(tags, removingUnreadable: ids)
    }

    internal func deleteTag(_ tag: ConnectionTag) {
        guard !tag.isPreset else { return }
        var tags = loadTags()
        tags.removeAll { $0.id == tag.id }
        guard saveTags(tags) else { return }
        syncTracker.markDeleted(.tag, id: tag.id.uuidString)
        notifyChanged()
    }

    /// Connections are persisted before the tag tombstone fires (sync delete-ordering invariant).
    internal func deleteTag(_ tag: ConnectionTag, clearingFrom connectionStorage: ConnectionStorage) {
        guard !tag.isPreset else { return }
        connectionStorage.removeTagId(tag.id)
        deleteTag(tag)
    }

    /// Keyed by lowercased name. A preset wins over a custom tag of the same name, and a missing
    /// preset is restored with its fixed id, so every Mac maps "production" to one record.
    internal func ensureTags(_ planned: [PlannedTag]) throws -> [String: UUID] {
        let wanted = planned.filter { !Self.matchKey($0.name).isEmpty }
        guard !wanted.isEmpty else { return [:] }
        var tags = loadTags()
        guard !storeIsUnreadable else { throw TagStorageError.storeUnreadable }

        // The id of a record this build cannot read is taken, so its preset is not restored over it.
        let takenIds = unreadableTagIds
        var ids: [String: UUID] = [:]
        var created = false
        for tag in wanted {
            let key = Self.matchKey(tag.name)
            if let match = Self.match(key, in: tags) {
                ids[tag.name.lowercased()] = match.id
                continue
            }
            let restorablePreset = ConnectionTag.presets.first { preset in
                Self.matchKey(preset.name) == key && !takenIds.contains(preset.id)
                    && !tags.contains { $0.id == preset.id }
            }
            let added = restorablePreset ?? ConnectionTag(
                name: tag.name.trimmingCharacters(in: .whitespacesAndNewlines),
                color: tag.color.map(ConnectionColor.init(storedValue:)) ?? .gray
            )
            tags.append(added)
            ids[tag.name.lowercased()] = added.id
            created = true
        }

        guard created else { return ids }
        guard saveTags(tags) else { throw TagStorageError.storeUnreadable }
        notifyChanged()
        return ids
    }

    internal func tag(for id: UUID) -> ConnectionTag? {
        loadTags().first { $0.id == id }
    }

    internal func tags(for ids: [UUID]) -> [ConnectionTag] {
        let allTags = loadTags()
        return ids.compactMap { id in allTags.first { $0.id == id } }
    }

    // MARK: - Private

    /// Announced from the mutators rather than from `saveTags`, because a sync pull applies one
    /// record at a time and raises a single coalesced notification of its own for the batch.
    private func notifyChanged() {
        appEvents.connectionUpdated.send(nil)
    }

    private static func matchKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func match(_ key: String, in tags: [ConnectionTag]) -> ConnectionTag? {
        let named = tags.filter { matchKey($0.name) == key }
        return named.first(where: \.isPreset) ?? named.first
    }
}
