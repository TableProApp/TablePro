//
//  ConnectionProject.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

struct ConnectionProject: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var color: ConnectionColor
    var iconName: String?
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        color: ConnectionColor = .none,
        iconName: String? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.iconName = iconName
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, iconName, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) ?? .none
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

extension ConnectionProject: LibraryProjectRepresentable {}
