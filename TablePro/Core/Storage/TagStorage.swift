//
//  TagStorage.swift
//  TablePro
//
//  Created by Claude on 20/12/25.
//

import Foundation
import os

/// Service for persisting the global tag library
final class TagStorage {
    static let shared = TagStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "TagStorage")

    private let tagsKey = "com.TablePro.tags"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        // Initialize with presets on first launch
        if loadTags().isEmpty {
            saveTags(ConnectionTag.presets)
        }
    }

    // MARK: - Tag CRUD

    /// Load all tags (presets + custom)
    func loadTags() -> [ConnectionTag] {
        guard let data = defaults.data(forKey: tagsKey) else {
            return ConnectionTag.presets
        }

        do {
            let tags = try decoder.decode([ConnectionTag].self, from: data)
            return tags
        } catch {
            Self.logger.error("Failed to load tags: \(error)")
            return ConnectionTag.presets
        }
    }

    /// Save all tags
    func saveTags(_ tags: [ConnectionTag]) {
        do {
            let data = try encoder.encode(tags)
            defaults.set(data, forKey: tagsKey)
            SyncChangeTracker.shared.markDirty(.tag, ids: tags.map { $0.id.uuidString })
        } catch {
            Self.logger.error("Failed to save tags: \(error)")
        }
    }

    /// Add a new custom tag
    func addTag(_ tag: ConnectionTag) {
        var tags = loadTags()
        // Prevent duplicates by name
        guard !tags.contains(where: { $0.name.lowercased() == tag.name.lowercased() }) else {
            return
        }
        tags.append(tag)
        saveTags(tags)
    }

    /// Delete a custom tag (presets cannot be deleted)
    func deleteTag(_ tag: ConnectionTag) {
        guard !tag.isPreset else { return }
        SyncChangeTracker.shared.markDeleted(.tag, id: tag.id.uuidString)
        var tags = loadTags()
        tags.removeAll { $0.id == tag.id }
        saveTags(tags)
    }

    /// Get tag by ID
    func tag(for id: UUID) -> ConnectionTag? {
        loadTags().first { $0.id == id }
    }

    /// Get tags for a list of IDs
    func tags(for ids: [UUID]) -> [ConnectionTag] {
        let allTags = loadTags()
        return ids.compactMap { id in allTags.first { $0.id == id } }
    }
}
