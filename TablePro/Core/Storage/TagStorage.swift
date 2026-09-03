//
//  TagStorage.swift
//  TablePro
//
//  Created by Claude on 20/12/25.
//

import Combine
import Foundation
import os
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

/// Service for persisting the global tag library
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
    /// Set when the stored payload could not be understood at all. Every mutation rewrites the
    /// whole array, so continuing over an unreadable store would replace a user's own tags with
    /// the preset list this falls back to for display.
    private var storeIsUnreadable = false

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

    /// Load all tags (presets + custom)
    ///
    /// A payload that decodes element by element keeps every tag it can read: one entry written by
    /// a future version, or truncated on disk, used to take the whole library down with it and
    /// leave the presets standing in its place.
    internal func loadTags() -> [ConnectionTag] {
        if let cached = cachedTags { return cached }

        guard let data = defaults.data(forKey: tagsKey) else {
            storeIsUnreadable = false
            let tags = ConnectionTag.presets
            cachedTags = tags
            return tags
        }

        if let tags = try? decoder.decode([ConnectionTag].self, from: data) {
            storeIsUnreadable = false
            cachedTags = tags
            return tags
        }

        guard let salvaged = try? decoder.decode([SalvagedTag].self, from: data) else {
            Self.logger.error("Tag store could not be read; leaving it untouched")
            storeIsUnreadable = true
            return ConnectionTag.presets
        }

        let tags = salvaged.compactMap(\.tag)
        Self.logger.error(
            "Dropped \(salvaged.count - tags.count, privacy: .public) unreadable tag entries"
        )
        storeIsUnreadable = false
        cachedTags = tags
        return tags
    }

    /// Save all tags. A save that failed leaves the store holding the previous set, so a caller
    /// that goes on to write related state must check the result.
    @discardableResult
    internal func saveTags(_ tags: [ConnectionTag]) -> Bool {
        guard !storeIsUnreadable else {
            Self.logger.error("Refusing to overwrite an unreadable tag store")
            return false
        }

        do {
            let data = try encoder.encode(tags)
            defaults.set(data, forKey: tagsKey)
            cachedTags = nil
            syncTracker.markDirty(.tag, ids: tags.map { $0.id.uuidString })
            return true
        } catch {
            Self.logger.error("Failed to save tags: \(error)")
            return false
        }
    }

    /// Add a new custom tag
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
    /// Written as it arrived, and skipped when it matches what is already stored: `saveTags` marks
    /// every tag dirty and the push uploads every dirty tag, so writing an unchanged record
    /// re-uploads the whole library to the device it came from, which writes it back.
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

    /// Delete a custom tag (presets cannot be deleted)
    internal func deleteTag(_ tag: ConnectionTag) {
        guard !tag.isPreset else { return }
        var tags = loadTags()
        tags.removeAll { $0.id == tag.id }
        guard saveTags(tags) else { return }
        syncTracker.markDeleted(.tag, id: tag.id.uuidString)
        notifyChanged()
    }

    /// Delete a custom tag and clear it from every connection that referenced it.
    /// Connections are persisted before the tag tombstone fires (sync delete-ordering invariant).
    internal func deleteTag(_ tag: ConnectionTag, clearingFrom connectionStorage: ConnectionStorage) {
        guard !tag.isPreset else { return }
        connectionStorage.removeTagId(tag.id)
        deleteTag(tag)
    }

    /// Get tag by ID
    internal func tag(for id: UUID) -> ConnectionTag? {
        loadTags().first { $0.id == id }
    }

    /// Get tags for a list of IDs
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
}

/// Decodes one tag and keeps going when it cannot, so a single unreadable entry costs that entry
/// rather than the whole library.
private struct SalvagedTag: Decodable {
    let tag: ConnectionTag?

    init(from decoder: Decoder) throws {
        tag = try? ConnectionTag(from: decoder)
    }
}
