import Foundation

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

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("query-history.json")
    }

    @discardableResult
    func save(_ item: QueryHistoryItem) -> Bool {
        var items = loadAll()
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
        guard let data = try? Data(contentsOf: fileURL),
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

    func clearAll(for connectionIds: Set<UUID>) {
        let items = loadAll()
        let kept = items.filter { !connectionIds.contains($0.connectionId) }
        guard kept.count != items.count else { return }
        writeAll(kept)
    }

    @discardableResult
    private func writeAll(_ items: [QueryHistoryItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])) != nil
    }
}
