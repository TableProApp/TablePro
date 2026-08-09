//
//  AIChatMessageSpacing.swift
//  TablePro
//

import Foundation

@MainActor
enum AIChatMessageSpacing {
    static func spacedMessageIDs(for messages: [ChatTurn]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for (previous, current) in zip(messages, messages.dropFirst())
        where current.role == .user && previous.role == .assistant {
            ids.insert(current.id)
        }
        return ids
    }
}
