//
//  ConnectionGroup.swift
//  TablePro
//

import Foundation

/// A group for organizing database connections into folders
struct ConnectionGroup: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var color: ConnectionColor
    var parentGroupId: UUID?
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        color: ConnectionColor = .blue,
        parentGroupId: UUID? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.parentGroupId = parentGroupId
        self.sortOrder = sortOrder
    }

    // MARK: - Codable (Migration Support)

    enum CodingKeys: String, CodingKey {
        case id, name, color, parentGroupId, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) ?? .blue
        parentGroupId = try container.decodeIfPresent(UUID.self, forKey: .parentGroupId)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}
