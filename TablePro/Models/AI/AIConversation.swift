//
//  AIConversation.swift
//  TablePro
//
//  Data model for a persisted AI chat conversation.
//

import Foundation

/// A persisted AI chat conversation
struct AIConversation: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var messages: [AIChatMessage]
    let createdAt: Date
    var updatedAt: Date
    var connectionName: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        messages: [AIChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        connectionName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.connectionName = connectionName
    }

    /// Derive title from the first user message (max 50 chars)
    mutating func updateTitle() {
        guard title.isEmpty,
              let firstUserMessage = messages.first(where: { $0.role == .user })
        else { return }

        let text = firstUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if (text as NSString).length > 50 {
            title = String(text.prefix(47)) + "..."
        } else {
            title = text
        }
    }
}
