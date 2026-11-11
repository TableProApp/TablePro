import Foundation
import os

nonisolated struct QueryHistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let query: String
    let timestamp: Date
    let connectionId: UUID
    let wasSuccessful: Bool
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        query: String,
        timestamp: Date = Date(),
        connectionId: UUID,
        wasSuccessful: Bool = true,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.query = query
        self.timestamp = timestamp
        self.connectionId = connectionId
        self.wasSuccessful = wasSuccessful
        self.errorMessage = errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        query = try container.decode(String.self, forKey: .query)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        connectionId = try container.decode(UUID.self, forKey: .connectionId)
        wasSuccessful = try container.decodeIfPresent(Bool.self, forKey: .wasSuccessful) ?? true
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

nonisolated struct QueryHistoryStorage {
    private static let maxEntries = 200
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryHistoryStorage")

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("query-history.json")
    }

    @discardableResult
    func save(_ item: QueryHistoryItem) -> Bool {
        guard var items = readAll() else { return false }
        if let last = items.last,
           last.query == item.query,
           last.connectionId == item.connectionId,
           last.wasSuccessful == item.wasSuccessful {
            return false
        }
        items.append(item)
        if items.count > Self.maxEntries {
            items.removeFirst(items.count - Self.maxEntries)
        }
        return writeAll(items)
    }

    func loadAll() -> [QueryHistoryItem] {
        readAll() ?? []
    }

    func load(for connectionId: UUID) -> [QueryHistoryItem] {
        loadAll().filter { $0.connectionId == connectionId }
    }

    func delete(_ id: UUID) {
        guard var items = readAll() else { return }
        items.removeAll { $0.id == id }
        writeAll(items)
    }

    // The set-aside copy holds every connection's history: only a clear asked for after the footer named it removes it.
    func clearAll(for connectionIds: Set<UUID>, removingSetAsideCopies: Bool = false) {
        guard let items = readAll() else { return }
        let kept = items.filter { !connectionIds.contains($0.connectionId) }
        if kept.count != items.count, !writeAll(kept) { return }
        if removingSetAsideCopies {
            removeSetAsideCopies()
        }
    }

    var hasSetAsideCopies: Bool {
        !setAsideCopies().isEmpty
    }

    private func setAsideCopies() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names
            .filter { $0.hasPrefix("query-history.damaged-") }
            .map { directory.appendingPathComponent($0) }
    }

    private func removeSetAsideCopies() {
        for copy in setAsideCopies() {
            do {
                try FileManager.default.removeItem(at: copy)
            } catch {
                Self.logger.error("A set-aside query history copy could not be deleted: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // nil while the file cannot be read (a locked device), so no write replaces it with a partial list.
    private func readAll() -> [QueryHistoryItem]? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let items = try? JSONDecoder().decode([QueryHistoryItem].self, from: data) {
            return items
        }
        return setAsideUndecodableFile() ? [] : nil
    }

    private func setAsideUndecodableFile() -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var attempt = 0
        var destination = directory.appendingPathComponent("query-history.damaged-\(stamp).json")
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            attempt += 1
            destination = directory.appendingPathComponent("query-history.damaged-\(stamp)-\(attempt).json")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            Self.logger.fault("Query history did not decode and was set aside")
            return true
        } catch {
            Self.logger.error("Query history did not decode and could not be set aside: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    @discardableResult
    private func writeAll(_ items: [QueryHistoryItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])) != nil
    }
}
