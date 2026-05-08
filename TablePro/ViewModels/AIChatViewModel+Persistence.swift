//
//  AIChatViewModel+Persistence.swift
//  TablePro
//

import Foundation

extension AIChatViewModel {
    func loadConversations() {
        let storage = chatStorage
        Task.detached(priority: .utility) { [weak self] in
            let loaded = await storage.loadAll()
            await MainActor.run {
                guard let self else { return }
                self.conversations = loaded
                if let mostRecent = loaded.first {
                    self.activeConversationID = mostRecent.id
                    self.messages = mostRecent.messages
                }
            }
        }
    }

    func clearConversation() {
        cancelStream()
        AIProviderFactory.resetCopilotConversation()
        Task { await chatStorage.deleteAll() }
        conversations.removeAll()
        messages.removeAll()
        activeConversationID = nil
        clearError()
    }

    func deleteConversation(_ id: UUID) {
        if activeConversationID == id {
            AIProviderFactory.resetCopilotConversation()
        }
        Task { await chatStorage.delete(id) }
        conversations.removeAll { $0.id == id }
        if activeConversationID == id {
            activeConversationID = nil
            messages.removeAll()
        }
    }

    func persistCurrentConversation() {
        guard !messages.isEmpty else { return }

        if let existingID = activeConversationID,
           var conversation = conversations.first(where: { $0.id == existingID }) {
            conversation.messages = messages
            conversation.updatedAt = Date()
            conversation.updateTitle()
            conversation.connectionName = connection?.name
            Task { await chatStorage.save(conversation) }

            if let index = conversations.firstIndex(where: { $0.id == existingID }) {
                conversations[index] = conversation
            }
        } else {
            var conversation = AIConversation(
                messages: messages,
                connectionName: connection?.name
            )
            conversation.updateTitle()
            Task { await chatStorage.save(conversation) }
            activeConversationID = conversation.id
            conversations.insert(conversation, at: 0)
        }
    }
}
