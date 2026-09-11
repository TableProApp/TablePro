//
//  HighlightRuleStorage.swift
//  TablePro
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class HighlightRuleStorage {
    static let shared = HighlightRuleStorage()

    nonisolated private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "HighlightRuleStorage"
    )

    private(set) var revision = 0

    @ObservationIgnored private let storageDirectory: URL
    @ObservationIgnored private var cache: [UUID: [String: [HighlightRule]]] = [:]
    @ObservationIgnored private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory ?? Self.resolvedStorageDirectory()
        do {
            try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create storage directory: \(error.localizedDescription)")
        }
    }

    func rules(for scope: TableScope) -> [HighlightRule] {
        _ = revision
        return loadEntries(for: scope.connectionId)[scope.storageComponent] ?? []
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

    func rename(from oldScope: TableScope, to newScope: TableScope) {
        guard oldScope.storageComponent != newScope.storageComponent else { return }
        var entries = loadEntries(for: oldScope.connectionId)
        guard let moving = entries.removeValue(forKey: oldScope.storageComponent) else { return }
        entries[newScope.storageComponent] = moving
        commit(entries, for: oldScope.connectionId)
    }

    func renameScope(
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

    func removeRules(for connectionIds: Set<UUID>) {
        guard !connectionIds.isEmpty else { return }
        for connectionId in connectionIds {
            cache[connectionId] = [:]
            removeFile(at: fileURL(for: connectionId))
        }
        revision &+= 1
    }

    private func commit(_ entries: [String: [HighlightRule]], for connectionId: UUID) {
        cache[connectionId] = entries
        if entries.isEmpty {
            removeFile(at: fileURL(for: connectionId))
        } else {
            write(entries, for: connectionId)
        }
        revision &+= 1
    }

    private func loadEntries(for connectionId: UUID) -> [String: [HighlightRule]] {
        if let cached = cache[connectionId] { return cached }

        let url = fileURL(for: connectionId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache[connectionId] = [:]
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode([String: [LossyHighlightRule]].self, from: data)
            let entries = decoded.compactMapValues { lossy -> [HighlightRule]? in
                let rules = lossy.compactMap(\.rule)
                return rules.isEmpty ? nil : rules
            }
            cache[connectionId] = entries
            return entries
        } catch {
            Self.logger.error(
                "Unreadable highlight rules for \(connectionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            preserveUnreadableFile(at: url)
            cache[connectionId] = [:]
            return [:]
        }
    }

    private func write(_ entries: [String: [HighlightRule]], for connectionId: UUID) {
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL(for: connectionId), options: .atomic)
        } catch {
            Self.logger.error(
                "Failed to write highlight rules for \(connectionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func preserveUnreadableFile(at url: URL) {
        let preserved = url.deletingPathExtension().appendingPathExtension("unreadable.json")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: preserved)
        do {
            try fileManager.moveItem(at: url, to: preserved)
        } catch {
            Self.logger.error("Failed to set aside unreadable highlight rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error("Failed to remove highlight rules file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL(for connectionId: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private static func resolvedStorageDirectory() -> URL {
        AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("HighlightRules", isDirectory: true)
    }
}

private struct LossyHighlightRule: Decodable {
    let rule: HighlightRule?

    init(from decoder: Decoder) throws {
        rule = try? HighlightRule(from: decoder)
    }
}
