//
//  TabDiskActor.swift
//  TablePro
//
//  Thread-safe actor for tab state persistence.
//  Replaces TabStateStorage with actor-based serialization
//  to eliminate data races on concurrent file writes.
//

import Foundation
import os

/// Persisted tab state for a connection
internal struct TabDiskState: Codable {
    let tabs: [PersistedTab]
    let selectedTabId: UUID?
}

/// Actor that serializes all tab-state disk I/O.
///
/// Data is stored as individual JSON files per connection in:
///   `~/Library/Application Support/TablePro/TabState/`
internal actor TabDiskActor {
    internal static let shared = TabDiskActor()

    private static let logger = Logger(subsystem: "com.TablePro", category: "TabDiskActor")

    // MARK: - Legacy UserDefaults Keys (for migration)

    private static let legacyTabStateKeyPrefix = "com.TablePro.tabs."
    private static let migrationCompleteKey = "com.TablePro.tabStateMigrationComplete"

    // MARK: - File Storage

    private let tabStateDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let directory = Self.resolvedTabStateDirectory()
        tabStateDirectory = directory
        encoder = JSONEncoder()
        decoder = JSONDecoder()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create directory \(directory.path): \(error.localizedDescription)")
        }
        Self.performMigrationIfNeeded(tabStateDirectory: directory)
    }

    // MARK: - Public API

    /// Save tab state for a connection. Throws on encoding or disk write failure.
    internal func save(connectionId: UUID, tabs: [PersistedTab], selectedTabId: UUID?) throws {
        let state = TabDiskState(tabs: tabs, selectedTabId: selectedTabId)
        let data = try encoder.encode(state)
        let fileURL = tabStateFileURL(for: connectionId)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Log a save error from callers that handle errors externally.
    nonisolated static func logSaveError(connectionId: UUID, error: Error) {
        logger.error("Failed to save tab state for \(connectionId): \(error.localizedDescription)")
    }

    /// Load tab state for a connection. Returns nil if the file is missing or corrupt.
    internal func load(connectionId: UUID) -> TabDiskState? {
        let fileURL = tabStateFileURL(for: connectionId)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(TabDiskState.self, from: data)
        } catch {
            Self.logger.error("Failed to load tab state for \(connectionId): \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete the tab state file for a connection.
    internal func clear(connectionId: UUID) {
        let fileURL = tabStateFileURL(for: connectionId)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Self.logger.error("Failed to clear tab state for \(connectionId): \(error.localizedDescription)")
        }
    }

    /// List all connection IDs that have saved tab state on disk.
    internal func connectionIdsWithSavedState() -> [UUID] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: tabStateDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files.compactMap { url -> UUID? in
            guard url.pathExtension == "json" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Static Path Helpers

    nonisolated private static func resolvedTabStateDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let baseDirectory = appSupport.appendingPathComponent("TablePro", isDirectory: true)
        return baseDirectory.appendingPathComponent("TabState", isDirectory: true)
    }

    nonisolated private static func tabStateFileURL(for connectionId: UUID) -> URL {
        resolvedTabStateDirectory().appendingPathComponent("\(connectionId.uuidString).json")
    }

    // MARK: - Synchronous Save (quit-time only)

    /// Synchronous file write for `applicationWillTerminate`, where no run loop
    /// remains to execute an async Task. Safe because the process is single-threaded
    /// at termination — no concurrent actor access is possible.
    nonisolated internal static func saveSync(
        connectionId: UUID,
        tabs: [PersistedTab],
        selectedTabId: UUID?
    ) {
        let state = TabDiskState(tabs: tabs, selectedTabId: selectedTabId)
        let encoder = JSONEncoder()

        do {
            let data = try encoder.encode(state)
            let directory = resolvedTabStateDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = tabStateFileURL(for: connectionId)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("saveSync failed for \(connectionId): \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func tabStateFileURL(for connectionId: UUID) -> URL {
        tabStateDirectory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    // MARK: - Migration from UserDefaults

    /// One-time migration: reads existing tab state from UserDefaults,
    /// writes it to file storage, then clears the old UserDefaults keys.
    /// This is a static method to avoid actor-isolation issues during init.
    private static func performMigrationIfNeeded(tabStateDirectory: URL) {
        let defaults = UserDefaults.standard

        guard !defaults.bool(forKey: migrationCompleteKey) else { return }

        logger.trace("Starting one-time migration of tab state from UserDefaults to file storage")

        var migratedTabStates = 0

        let allKeys = defaults.dictionaryRepresentation().keys
        let tabStateKeys = allKeys.filter { $0.hasPrefix(legacyTabStateKeyPrefix) }

        for key in tabStateKeys {
            let uuidString = String(key.dropFirst(legacyTabStateKeyPrefix.count))
            guard let connectionId = UUID(uuidString: uuidString),
                  let data = defaults.data(forKey: key) else { continue }

            let fileURL = tabStateDirectory.appendingPathComponent("\(connectionId.uuidString).json")
            do {
                try data.write(to: fileURL, options: .atomic)
                defaults.removeObject(forKey: key)
                migratedTabStates += 1
            } catch {
                logger.error("Failed to migrate tab state for \(uuidString): \(error.localizedDescription)")
            }
        }

        defaults.set(true, forKey: migrationCompleteKey)

        if migratedTabStates > 0 {
            logger.trace("Migration complete: \(migratedTabStates) tab states")
        } else {
            logger.trace("Migration complete: no legacy data found")
        }
    }
}
