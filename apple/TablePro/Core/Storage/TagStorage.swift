//
//  TagStorage.swift
//  TablePro
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

    private let syncJournal: SyncHostJournal
    private let connectionStorageProvider: () -> ConnectionStorage
    private let appEvents: AppEvents
    /// Set when the library could not be read. Every mutation rewrites the whole library, so
    /// continuing over an unreadable one would replace a user's own tags with the preset list this
    /// falls back to for display.
    internal private(set) var storeIsUnreadable = false

    internal init(
        syncJournal: SyncHostJournal = .shared,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared,
        appEvents: AppEvents = .shared
    ) {
        self.syncJournal = syncJournal
        self.connectionStorageProvider = connectionStorage
        self.appEvents = appEvents
        if loadTags().isEmpty {
            saveTags(ConnectionTag.presets)
        }
    }

    // MARK: - Tag CRUD

    internal func loadTags() -> [ConnectionTag] {
        guard let image = connectionStorageProvider().library.current() else {
            Self.logger.error("The connection library could not be read; leaving the tags untouched")
            storeIsUnreadable = true
            return ConnectionTag.presets
        }
        storeIsUnreadable = false
        return image.tags
    }

    // False leaves the store holding the previous set, so a caller that goes on to write related state checks it.
    @discardableResult
    internal func saveTags(_ tags: [ConnectionTag]) -> Bool {
        let previous = loadTags()
        let library = connectionStorageProvider().library
        guard !storeIsUnreadable, var image = library.current() else {
            Self.logger.error("Refusing to overwrite an unreadable tag store")
            return false
        }
        image.tags = tags
        guard library.commit(image, byUser: false) else {
            Self.logger.error("Failed to save tags")
            return false
        }
        syncJournal.recorded(.tag, written: SyncRecordChanges.changedIds(from: previous, to: tags))
        return true
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

    internal func deleteTag(_ tag: ConnectionTag) {
        guard !tag.isPreset else { return }
        var tags = loadTags()
        tags.removeAll { $0.id == tag.id }
        guard saveTags(tags) else { return }
        syncJournal.recorded(.tag, deleted: [tag.id.uuidString])
        notifyChanged()
    }

    /// Connections are persisted before the tag's deletion is journaled.
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

        var ids: [String: UUID] = [:]
        var created = false
        for tag in wanted {
            let key = Self.matchKey(tag.name)
            if let match = Self.match(key, in: tags) {
                ids[tag.name.lowercased()] = match.id
                continue
            }
            let restorablePreset = ConnectionTag.presets.first { preset in
                Self.matchKey(preset.name) == key && !tags.contains { $0.id == preset.id }
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
