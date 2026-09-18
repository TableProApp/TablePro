//
//  AIConversation.swift
//  TablePro
//

import Foundation

struct AIConversation: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let id: UUID
    var title: String
    var messages: [ChatTurnWire]
    let createdAt: Date
    var updatedAt: Date
    /// Which connection this conversation belongs to.
    ///
    /// Without it every window read the same flat directory and restored whichever file was newest,
    /// so a second connection opened holding the first one's transcript and then saved over it.
    /// Optional because conversations written before this existed have no answer, and a conversation
    /// with no connection is shown everywhere rather than nowhere.
    let connectionId: UUID?
    var connectionName: String?
    let schemaVersion: Int

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
