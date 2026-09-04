//
//  AIConversation.swift
//  TablePro
//

import Foundation

struct AIConversation: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    let id: UUID
    var title: String
    var messages: [ChatTurnWire]
    let createdAt: Date
    var updatedAt: Date
    var connectionId: UUID?
    var connectionName: String?
    let schemaVersion: Int

    /// A record written before schema 2 carries no connection id. It is never matched back to a
    /// connection by name, because duplicate names are ordinary and a wrong match would attach a
    /// production transcript to a development connection.
    var isOrphan: Bool { connectionId == nil }

    init(
        id: UUID = UUID(),
        title: String = "",
        messages: [ChatTurnWire] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        connectionId: UUID? = nil,
        connectionName: String? = nil,
        schemaVersion: Int = AIConversation.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        messages = try container.decodeIfPresent([ChatTurnWire].self, forKey: .messages) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        connectionId = try container.decodeIfPresent(UUID.self, forKey: .connectionId)
        connectionName = try container.decodeIfPresent(String.self, forKey: .connectionName)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        schemaVersion = max(storedVersion, AIConversation.currentSchemaVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, connectionId, connectionName, schemaVersion
    }

    mutating func updateTitle() {
        guard title.isEmpty,
              let firstUserMessage = messages.first(where: { $0.role == .user })
        else { return }

        let text = firstUserMessage.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if (text as NSString).length > 50 {
            title = String(text.prefix(47)) + "…"
        } else {
            title = text
        }
    }
}
