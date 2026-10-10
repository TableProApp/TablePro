import Foundation

public struct ConnectionGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var color: ConnectionColor
    /// An SF Symbol the user picked to draw instead of the folder. Nil draws the folder.
    public var iconName: String?
    public var parentId: UUID?

    public init(
        id: UUID = UUID(),
        name: String = "",
        sortOrder: Int = 0,
        color: ConnectionColor = .none,
        iconName: String? = nil,
        parentId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.color = color
        self.iconName = iconName
        self.parentId = parentId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, color, iconName, parentId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        color = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) ?? .none
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        parentId = try container.decodeIfPresent(UUID.self, forKey: .parentId)
    }
}
