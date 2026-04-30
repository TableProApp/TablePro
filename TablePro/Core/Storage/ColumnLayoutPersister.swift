//
//  ColumnLayoutPersister.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class FileColumnLayoutPersister: ColumnLayoutPersisting {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ColumnLayoutPersister")
    private static let legacyKeyPrefix = "com.TablePro.columns.layout."
    private static let migrationCompleteKey = "com.TablePro.columnLayoutMigrationComplete"

    private struct PersistedColumnLayout: Codable {
        var columnWidths: [String: CGFloat]
        var columnOrder: [String]?
    }

    private let storageDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cache: [UUID: [String: PersistedColumnLayout]] = [:]

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory ?? Self.resolvedStorageDirectory()

        do {
            try FileManager.default.createDirectory(
                at: self.storageDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create storage directory: \(error.localizedDescription)")
        }

        Self.performMigrationIfNeeded(storageDirectory: self.storageDirectory)
    }

    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {
        guard !layout.columnWidths.isEmpty else { return }

        let persisted = PersistedColumnLayout(
            columnWidths: layout.columnWidths,
            columnOrder: layout.columnOrder
        )

        var entries = loadEntries(for: connectionId)
        entries[tableName] = persisted
        cache[connectionId] = entries
        writeEntries(entries, for: connectionId)
    }

    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? {
        let entries = loadEntries(for: connectionId)
        guard let persisted = entries[tableName] else { return nil }

        var state = ColumnLayoutState()
        state.columnWidths = persisted.columnWidths
        state.columnOrder = persisted.columnOrder
        return state
    }

    func clear(for tableName: String, connectionId: UUID) {
        var entries = loadEntries(for: connectionId)
        guard entries.removeValue(forKey: tableName) != nil else { return }

        if entries.isEmpty {
            cache[connectionId] = [:]
            removeFile(for: connectionId)
        } else {
            cache[connectionId] = entries
            writeEntries(entries, for: connectionId)
        }
    }

    private func loadEntries(for connectionId: UUID) -> [String: PersistedColumnLayout] {
        if let cached = cache[connectionId] { return cached }

        let fileURL = fileURL(for: connectionId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache[connectionId] = [:]
            return [:]
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let entries = try decoder.decode([String: PersistedColumnLayout].self, from: data)
            cache[connectionId] = entries
            return entries
        } catch {
            Self.logger.error(
                "Failed to load column layouts for \(connectionId): \(error.localizedDescription)"
            )
            cache[connectionId] = [:]
            return [:]
        }
    }

    private func writeEntries(_ entries: [String: PersistedColumnLayout], for connectionId: UUID) {
        let fileURL = fileURL(for: connectionId)
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error(
                "Failed to write column layouts for \(connectionId): \(error.localizedDescription)"
            )
        }
    }

    private func removeFile(for connectionId: UUID) {
        let fileURL = fileURL(for: connectionId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Self.logger.error(
                "Failed to remove column layout file for \(connectionId): \(error.localizedDescription)"
            )
        }
    }

    private func fileURL(for connectionId: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private static func resolvedStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("ColumnLayout", isDirectory: true)
    }

    private static func performMigrationIfNeeded(storageDirectory: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationCompleteKey) else { return }

        let allKeys = defaults.dictionaryRepresentation().keys
        let legacyKeys = allKeys.filter { $0.hasPrefix(legacyKeyPrefix) }

        var grouped: [UUID: [String: PersistedColumnLayout]] = [:]
        let decoder = JSONDecoder()

        for key in legacyKeys {
            let suffix = String(key.dropFirst(legacyKeyPrefix.count))
            guard let dotIndex = suffix.firstIndex(of: ".") else { continue }

            let uuidString = String(suffix[..<dotIndex])
            let tableName = String(suffix[suffix.index(after: dotIndex)...])

            guard let connectionId = UUID(uuidString: uuidString),
                  let data = defaults.data(forKey: key),
                  let persisted = try? decoder.decode(PersistedColumnLayout.self, from: data) else {
                defaults.removeObject(forKey: key)
                continue
            }

            grouped[connectionId, default: [:]][tableName] = persisted
        }

        let encoder = JSONEncoder()
        for (connectionId, entries) in grouped {
            let fileURL = storageDirectory.appendingPathComponent("\(connectionId.uuidString).json")
            do {
                let data = try encoder.encode(entries)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                logger.error(
                    "Migration failed for \(connectionId): \(error.localizedDescription)"
                )
            }
        }

        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: migrationCompleteKey)

        if !grouped.isEmpty {
            logger.trace("Migrated \(grouped.count) connection(s) of column layouts to file storage")
        }
    }
}
