import Foundation

public struct ConnectionProject: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var color: ConnectionColor
    public var iconName: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        sortOrder: Int = 0,
        color: ConnectionColor = .none,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.color = color
        self.iconName = iconName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, color, iconName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        color = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) ?? .none
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
    }
}
