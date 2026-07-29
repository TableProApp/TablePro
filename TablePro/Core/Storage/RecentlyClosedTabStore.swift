import Foundation
import Observation
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

/// Durable history of recently closed tabs, deliberately independent of `TabDiskActor`.
/// `TabDiskActor` answers "what is open right now" and is recomputed from the surviving
/// windows on every save, so a closed tab necessarily falls out of it. This store is the
/// append-and-prune log that lets a closed tab come back.
@MainActor
@Observable
internal final class RecentlyClosedTabStore {
    internal static let shared = RecentlyClosedTabStore()

    internal static let maxEntries = 20
    internal static let maxAge: TimeInterval = 60 * 60 * 24 * 30

    private static let logger = Logger(subsystem: "com.TablePro", category: "RecentlyClosedTabStore")

    internal private(set) var entries: [RecentlyClosedTabEntry] = []

    @ObservationIgnored private let directory: URL

    internal init(directory: URL = RecentlyClosedTabStore.defaultDirectory()) {
        self.directory = directory
        createDirectories()
        entries = Self.decodeEntries(at: Self.stateFileURL(in: directory))
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

    /// Removes the entry and returns it with any overflow text folded back into the tab, so the
    /// caller holds everything needed to rebuild the tab without touching disk again.
    internal func consume(id: UUID) -> RecentlyClosedTabEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var entry = entries.remove(at: index)
        if let overflow = overflowText(for: entry) {
            entry.tab.query = overflow
        }
        removeOverflowFile(for: entry)
        entry.overflowFileName = nil
        persist()
        return entry
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

    /// A query above `maxPersistableQuerySize` is blanked by `toPersistedTab()` to keep the
    /// tab-state JSON small. A recovery entry cannot afford that, so the full text goes to a
    /// sidecar file instead of being silently truncated.
    private func writeOverflow(_ query: String, fileName: String) -> Bool {
        do {
            try query.write(to: overflowDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
            return true
        } catch {
            Self.logger.fault("Failed to write overflow query \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            Self.logger.error("Failed to create directory \(self.overflowDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.stateFileURL(in: directory), options: .atomic)
        } catch {
            Self.logger.fault("Failed to persist recently closed tabs: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One unreadable entry must not cost the user the rest of the history, so entries decode
    /// leniently, matching `TabDiskState`.
    private static func decodeEntries(at url: URL) -> [RecentlyClosedTabEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([LossyEntry].self, from: data).compactMap(\.value)
        } catch {
            logger.error("Failed to load recently closed tabs: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    nonisolated internal static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("RecentlyClosedTabs", isDirectory: true)
    }

    private static func stateFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("entries.json")
    }
}

private struct LossyEntry: Decodable {
    let value: RecentlyClosedTabEntry?

    init(from decoder: Decoder) throws {
        value = try? RecentlyClosedTabEntry(from: decoder)
    }
}
