import Combine
import Foundation
import os

internal struct RecentlyClosedTabEntry: Codable, Identifiable {
    internal let id: UUID
    internal let closedAt: Date
    internal let connectionId: UUID
    internal let connectionName: String
    internal var tab: PersistedTab
    internal var overflowFileName: String?
}

internal extension RecentlyClosedTabEntry {
    var displayTitle: String {
        String(format: String(localized: "%1$@ (%2$@)"), contentTitle, connectionName)
    }

    private var contentTitle: String {
        if tab.tabType == .table, let tableName = tab.tableName, !tableName.isEmpty {
            return tableName
        }
        if let url = tab.sourceFileURL {
            return QueryTab.fileDisplayTitle(for: url)
        }
        if tab.automaticTitle != nil {
            return tab.title
        }
        return queryPreview ?? tab.title
    }

    private var queryPreview: String? {
        let firstLine = tab.query
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstLine else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > Self.previewLength else { return trimmed }
        return trimmed.prefix(Self.previewLength).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private static let previewLength = 48
}

// Independent of `TabDiskActor`, which is recomputed from the surviving windows on every save and so drops a closed tab.
@MainActor
internal final class RecentlyClosedTabStore: ObservableObject {
    internal static let shared = RecentlyClosedTabStore()

    internal static let maxEntries = 20
    internal static let maxAge: TimeInterval = 60 * 60 * 24 * 30

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RecentlyClosedTabStore")

    @Published internal private(set) var entries: [RecentlyClosedTabEntry] = []

    private let directory: URL
    private let stateFile: JSONFileStore<StoredEntries>

    internal init(directory: URL = RecentlyClosedTabStore.defaultDirectory()) {
        self.directory = directory
        stateFile = JSONFileStore(url: directory.appendingPathComponent("entries.json"))
        createDirectories()
        entries = stateFile.read().value?.entries ?? []
        prune()
        persist()
    }

    // MARK: - Capture

    internal func push(tab: QueryTab, connection: DatabaseConnection) {
        guard tab.isReopenCandidate, let entry = makeEntry(tab: tab, connection: connection) else { return }
        discardEntries { $0.tab.id == tab.id }
        entries.insert(entry, at: 0)
        prune()
        persist()
    }

    // MARK: - Recovery

    internal var mostRecentEntry: RecentlyClosedTabEntry? {
        entries.first
    }

    // Removes nothing: opening the tab can still fail or wait on a connect, so the caller discards it once shown.
    internal func restorableEntry(id: UUID) -> RecentlyClosedTabEntry? {
        guard var entry = entries.first(where: { $0.id == id }) else { return nil }
        if let overflow = overflowText(for: entry) {
            entry.tab.query = overflow
        }
        entry.overflowFileName = nil
        return entry
    }

    internal func containsEntry(id: UUID) -> Bool {
        entries.contains { $0.id == id }
    }

    internal func discard(id: UUID) {
        guard containsEntry(id: id) else { return }
        discardEntries { $0.id == id }
        persist()
    }

    // MARK: - Connection Removal

    internal func removeEntries(for connectionId: UUID) {
        removeEntries(for: Set([connectionId]))
    }

    internal func removeEntries(for connectionIds: Set<UUID>) {
        discardEntries { connectionIds.contains($0.connectionId) }
        persist()
    }

    // MARK: - Entry Construction

    private func makeEntry(tab: QueryTab, connection: DatabaseConnection) -> RecentlyClosedTabEntry? {
        let entryId = UUID()
        var persisted = tab.toPersistedTab()
        var overflowFileName: String?

        if (tab.content.query as NSString).length > TabQueryContent.maxPersistableQuerySize {
            let fileName = "\(entryId.uuidString).sql"
            guard writeOverflow(tab.content.query, fileName: fileName) else { return nil }
            overflowFileName = fileName
            persisted.query = ""
        }

        return RecentlyClosedTabEntry(
            id: entryId,
            closedAt: Date(),
            connectionId: connection.id,
            connectionName: connection.name,
            tab: persisted,
            overflowFileName: overflowFileName
        )
    }

    // MARK: - Pruning

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var kept: [RecentlyClosedTabEntry] = []
        var dropped: [RecentlyClosedTabEntry] = []

        for entry in entries {
            if entry.closedAt < cutoff || kept.count >= Self.maxEntries {
                dropped.append(entry)
            } else {
                kept.append(entry)
            }
        }

        dropped.forEach(removeOverflowFile)
        entries = kept
    }

    private func discardEntries(where shouldDiscard: (RecentlyClosedTabEntry) -> Bool) {
        let dropped = entries.filter(shouldDiscard)
        guard !dropped.isEmpty else { return }
        dropped.forEach(removeOverflowFile)
        entries.removeAll(where: shouldDiscard)
    }

    // MARK: - Overflow Files

    // `toPersistedTab()` blanks a query above `maxPersistableQuerySize`, so the full text goes to a sidecar file.
    private func writeOverflow(_ query: String, fileName: String) -> Bool {
        do {
            try query.write(to: overflowDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
            return true
        } catch {
            Self.logger.fault("Failed to write overflow query \(fileName, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return false
        }
    }

    private func overflowText(for entry: RecentlyClosedTabEntry) -> String? {
        guard let fileName = entry.overflowFileName else { return nil }
        return try? String(contentsOf: overflowDirectory.appendingPathComponent(fileName), encoding: .utf8)
    }

    private func removeOverflowFile(for entry: RecentlyClosedTabEntry) {
        guard let fileName = entry.overflowFileName else { return }
        try? FileManager.default.removeItem(at: overflowDirectory.appendingPathComponent(fileName))
    }

    // MARK: - Disk

    private var overflowDirectory: URL {
        directory.appendingPathComponent("Overflow", isDirectory: true)
    }

    private func createDirectories() {
        do {
            try FileManager.default.createDirectory(at: overflowDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create directory \(self.overflowDirectory.path, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)")
        }
    }

    private func persist() {
        try? stateFile.write(StoredEntries(entries))
    }

    nonisolated internal static func defaultDirectory() -> URL {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        return appSupport
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("RecentlyClosedTabs", isDirectory: true)
    }
}

// Entries decode one by one, matching `TabDiskState`, so one unreadable entry does not cost the rest of the history.
private struct StoredEntries: Codable {
    let entries: [RecentlyClosedTabEntry]

    init(_ entries: [RecentlyClosedTabEntry]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        entries = try decoder.singleValueContainer().decode([LossyEntry].self).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

private struct LossyEntry: Decodable {
    let value: RecentlyClosedTabEntry?

    init(from decoder: Decoder) throws {
        value = try? RecentlyClosedTabEntry(from: decoder)
    }
}
