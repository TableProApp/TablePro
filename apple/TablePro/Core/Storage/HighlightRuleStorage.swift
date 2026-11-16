//
//  HighlightRuleStorage.swift
//  TablePro
//

import Combine
import Foundation
import os

@MainActor
final class HighlightRuleStorage: ObservableObject, TableScopedSettingsStore {
    static let shared = HighlightRuleStorage()

    nonisolated private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "HighlightRuleStorage"
    )

    @Published private(set) var revision = 0

    private let storageDirectory: URL
    private var cache: [UUID: [String: [HighlightRule]]] = [:]

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory ?? Self.resolvedStorageDirectory()
        do {
            try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create storage directory: \(error.localizedDescription)")
        }
    }

    func rules(for scope: TableScope) -> [HighlightRule] {
        loadEntries(for: scope.connectionId)[scope.storageComponent] ?? []
    }

    func setRules(_ rules: [HighlightRule], for scope: TableScope) {
        var entries = loadEntries(for: scope.connectionId)
        guard entries[scope.storageComponent, default: []] != rules else { return }
        if rules.isEmpty {
            entries.removeValue(forKey: scope.storageComponent)
        } else {
            entries[scope.storageComponent] = rules
        }
        commit(entries, for: scope.connectionId)
    }

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        guard oldScope.storageComponent != newScope.storageComponent else { return }
        var entries = loadEntries(for: oldScope.connectionId)
        guard let moving = entries.removeValue(forKey: oldScope.storageComponent) else { return }
        entries[newScope.storageComponent] = moving
        commit(entries, for: oldScope.connectionId)
    }

    func renameContainer(
        connectionId: UUID,
        fromDatabase: String,
        fromSchema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        let oldPrefix = TableScope.storagePrefix(connectionId: connectionId, database: fromDatabase, schema: fromSchema)
        let newPrefix = TableScope.storagePrefix(connectionId: connectionId, database: toDatabase, schema: toSchema)
        guard oldPrefix != newPrefix else { return }

        var entries = loadEntries(for: connectionId)
        let moving = entries.keys.filter { $0.hasPrefix(oldPrefix) }
        guard !moving.isEmpty else { return }
        for key in moving {
            entries[newPrefix + key.dropFirst(oldPrefix.count)] = entries.removeValue(forKey: key)
        }
        commit(entries, for: connectionId)
    }

    func dropTable(_ scope: TableScope) {
        setRules([], for: scope)
    }

    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        let prefix = TableScope.storagePrefix(connectionId: connectionId, database: database, schema: schema)
        var entries = loadEntries(for: connectionId)
        let dropping = entries.keys.filter { $0.hasPrefix(prefix) }
        guard !dropping.isEmpty else { return }
        for key in dropping {
            entries.removeValue(forKey: key)
        }
        commit(entries, for: connectionId)
    }

    func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
        guard !connectionIds.isEmpty else { return }
        for connectionId in connectionIds {
            cache[connectionId] = [:]
            try? file(for: connectionId).remove()
            removeFile(at: unreadableFileURL(for: connectionId))
        }
        revision &+= 1
    }

    private func commit(_ entries: [String: [HighlightRule]], for connectionId: UUID) {
        cache[connectionId] = entries
        if entries.isEmpty {
            try? file(for: connectionId).remove()
        } else {
            try? file(for: connectionId).write(StoredRules(entries))
        }
        revision &+= 1
    }

    private func loadEntries(for connectionId: UUID) -> [String: [HighlightRule]] {
        if let cached = cache[connectionId] { return cached }

        let entries: [String: [HighlightRule]]
        switch file(for: connectionId).read() {
        case .missing:
            entries = [:]
        case .value(let stored):
            entries = stored.entries
        case .unreadable:
            preserveUnreadableFile(for: connectionId)
            entries = [:]
        }
        cache[connectionId] = entries
        return entries
    }

    private func preserveUnreadableFile(for connectionId: UUID) {
        let preserved = unreadableFileURL(for: connectionId)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: preserved)
        do {
            try fileManager.moveItem(at: fileURL(for: connectionId), to: preserved)
        } catch {
            Self.logger.error("Failed to set aside unreadable highlight rules: \(error.publicLogShape, privacy: .public)")
        }
    }

    private func removeFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error("Failed to remove highlight rules file: \(error.publicLogShape, privacy: .public)")
        }
    }

    private func unreadableFileURL(for connectionId: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(connectionId.uuidString).unreadable.json")
    }

    private func fileURL(for connectionId: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private func file(for connectionId: UUID) -> JSONFileStore<StoredRules> {
        JSONFileStore(url: fileURL(for: connectionId), coding: .sortedKeys)
    }

    private static func resolvedStorageDirectory() -> URL {
        AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("HighlightRules", isDirectory: true)
    }
}

// Rules decode one by one, so one this build cannot read does not cost the rest, and a table left with none drops out.
private struct StoredRules: Codable {
    let entries: [String: [HighlightRule]]

    init(_ entries: [String: [HighlightRule]]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let decoded = try decoder.singleValueContainer().decode([String: [LossyHighlightRule]].self)
        entries = decoded.compactMapValues { lossy -> [HighlightRule]? in
            let rules = lossy.compactMap(\.rule)
            return rules.isEmpty ? nil : rules
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

private struct LossyHighlightRule: Decodable {
    let rule: HighlightRule?

    init(from decoder: Decoder) throws {
        rule = try? HighlightRule(from: decoder)
    }
}
