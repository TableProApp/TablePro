import Foundation

struct QueryHistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let query: String
    let timestamp: Date
    let connectionId: UUID

    init(id: UUID = UUID(), query: String, timestamp: Date = Date(), connectionId: UUID) {
        self.id = id
        self.query = query
        self.timestamp = timestamp
        self.connectionId = connectionId
    }
}

struct QueryHistoryStorage {
    private static let maxEntries = 200

    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = dir.appendingPathComponent("TableProMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("query-history.json")
    }

    func save(_ item: QueryHistoryItem) {
        var items = loadAll()
        if items.last?.query == item.query && items.last?.connectionId == item.connectionId {
            return
        }
        items.append(item)
        if items.count > Self.maxEntries {
            items.removeFirst(items.count - Self.maxEntries)
        }
        writeAll(items)
    }

    func loadAll() -> [QueryHistoryItem] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([QueryHistoryItem].self, from: data) else {
            return []
        }
        return items
    }

    func load(for connectionId: UUID) -> [QueryHistoryItem] {
        loadAll().filter { $0.connectionId == connectionId }
    }

    func delete(_ id: UUID) {
        var items = loadAll()
        items.removeAll { $0.id == id }
        writeAll(items)
    }

    func clearAll(for connectionId: UUID) {
        var items = loadAll()
        items.removeAll { $0.connectionId == connectionId }
        writeAll(items)
    }

    private func writeAll(_ items: [QueryHistoryItem]) {
        guard let fileURL, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
