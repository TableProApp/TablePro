//
//  ConnectionTag.swift
//  TablePro
//
//  Created by Claude on 20/12/25.
//

import Foundation

/// A tag that can be assigned to connections for organization
struct ConnectionTag: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var isPreset: Bool  // Preset tags cannot be deleted
    var color: ConnectionColor  // Tag display color

    init(id: UUID = UUID(), name: String, isPreset: Bool = false, color: ConnectionColor = .gray) {
        self.id = id
        self.name = name
        self.isPreset = isPreset
        self.color = color
    }

    // MARK: - Codable (Migration Support)

    enum CodingKeys: String, CodingKey {
        case id, name, isPreset, color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isPreset = try container.decode(Bool.self, forKey: .isPreset)
        // Migration: tags without color default to gray
        color = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) ?? .gray
    }
}

// MARK: - Preset Tags

extension ConnectionTag {
    /// Preset tags available by default
    static let presets: [ConnectionTag] = [
        ConnectionTag(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            name: "local",
            isPreset: true,
            color: .green
        ),
        ConnectionTag(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID(),
            name: "development",
            isPreset: true,
            color: .blue
        ),
        ConnectionTag(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003") ?? UUID(),
            name: "production",
            isPreset: true,
            color: .red
        ),
        ConnectionTag(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004") ?? UUID(),
            name: "testing",
            isPreset: true,
            color: .orange
        ),
    ]
}
