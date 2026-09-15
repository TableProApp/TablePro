import Foundation

public struct RecentConnectionsLedger: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public let id: UUID
        public let connectedAt: Date

        public init(id: UUID, connectedAt: Date) {
            self.id = id
            self.connectedAt = connectedAt
        }
    }

    public static let capacity = 200

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Self.normalized(entries)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        entries = Self.normalized(decoded)
    }

    public var lastConnected: [UUID: Date] {
        Dictionary(entries.map { ($0.id, $0.connectedAt) }, uniquingKeysWith: { first, _ in first })
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public mutating func record(_ id: UUID, at date: Date) {
        entries = Self.normalized([Entry(id: id, connectedAt: date)] + entries.filter { $0.id != id })
    }

    public mutating func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    public mutating func retain(only ids: Set<UUID>) {
        entries.removeAll { !ids.contains($0.id) }
    }

    public mutating func removeAll() {
        entries = []
    }

    private static func normalized(_ entries: [Entry]) -> [Entry] {
        var newestById: [UUID: Entry] = [:]
        for entry in entries {
            if let existing = newestById[entry.id], existing.connectedAt >= entry.connectedAt { continue }
            newestById[entry.id] = entry
        }
        return newestById.values
            .sorted { $0.connectedAt == $1.connectedAt ? $0.id.uuidString < $1.id.uuidString : $0.connectedAt > $1.connectedAt }
            .prefix(capacity)
            .map { $0 }
    }
}
