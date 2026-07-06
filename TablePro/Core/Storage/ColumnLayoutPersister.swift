//
//  ColumnLayoutPersister.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class FileColumnLayoutPersister: ColumnLayoutPersisting {
    static let shared: FileColumnLayoutPersister = {
        let persister = FileColumnLayoutPersister()
        persister.performScopeMigration()
        return persister
    }()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ColumnLayoutPersister")
    private static let legacyUserDefaultsPrefix = "com.TablePro.columns.layout."
    private static let legacyVisibilityPrefix = "com.TablePro.columns.hiddenColumns."
    private static let scopeMigrationKey = "com.TablePro.columnLayoutSchemaScopeMigrationComplete"

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
    }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {
        guard !layout.columnWidths.isEmpty else { return }

        let persisted = PersistedColumnLayout(
            columnWidths: layout.columnWidths,
            columnOrder: layout.columnOrder
        )

        var entries = loadEntries(for: key.connectionId)
        entries[key.storageKey] = persisted
        cache[key.connectionId] = entries
        writeEntries(entries, for: key.connectionId)
    }

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? {
        let entries = loadEntries(for: key.connectionId)
        guard let persisted = entries[key.storageKey] else { return nil }

        var state = ColumnLayoutState()
        state.columnWidths = persisted.columnWidths
        state.columnOrder = persisted.columnOrder
        return state
    }

    func clear(for key: ColumnLayoutTableKey) {
        var entries = loadEntries(for: key.connectionId)
        guard entries.removeValue(forKey: key.storageKey) != nil else { return }

        if entries.isEmpty {
            cache[key.connectionId] = [:]
            removeFile(for: key.connectionId)
        } else {
            cache[key.connectionId] = entries
            writeEntries(entries, for: key.connectionId)
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

    private func performScopeMigration() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.scopeMigrationKey) else { return }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let legacyKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(Self.legacyUserDefaultsPrefix) || $0.hasPrefix(Self.legacyVisibilityPrefix)
        }
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: Self.scopeMigrationKey)
    }
}
