import Foundation

public struct SavedQuery: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var query: String
    public var keyword: String?
    public var folderId: UUID?
    public var connectionId: UUID?
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        query: String,
        keyword: String? = nil,
        folderId: UUID? = nil,
        connectionId: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        let now = Date()
        self.id = id
        self.name = name
        self.query = query
        self.keyword = keyword
        self.folderId = folderId
        self.connectionId = connectionId
        self.sortOrder = sortOrder
        self.createdAt = createdAt ?? now
        self.updatedAt = updatedAt ?? now
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, query, keyword, folderId, connectionId, sortOrder, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        query = try container.decode(String.self, forKey: .query)
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        folderId = try container.decodeIfPresent(UUID.self, forKey: .folderId)
        connectionId = try container.decodeIfPresent(UUID.self, forKey: .connectionId)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        // The keyword contest is decided by createdAt, so a row without one is refused rather than dated now.
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}
