//
//  AIChatViewModel+Persistence.swift
//  TablePro
//

import Foundation

extension AIChatViewModel {
    /// Brings in this connection's conversation history, and this session's own transcript.
    ///
    /// Called when a session is first looked at rather than from `init`, and scoped to the
    /// connection. Loading every conversation and restoring whichever happened to be newest meant a
    /// second connection's window opened holding the first connection's transcript, and then saved
    /// over it.
    func restoreConversationsIfNeeded() {
        guard !hasRestoredConversation else { return }
        markConversationRestored()
        let storage = chatStorage
        let connectionId = connection?.id
        let wanted = pendingConversationToRestore
        Task.detached(priority: .utility) { [weak self] in
            let loaded = await storage.loadAll(connectionId: connectionId)
            await MainActor.run {
                guard let self else { return }
                self.conversations = loaded
                guard self.messages.isEmpty else { return }
                guard let wanted, let stored = loaded.first(where: { $0.id == wanted }) else { return }
                self.activeConversationID = stored.id
                self.messages = stored.messages.map { ChatTurn(wire: $0) }
            }
        }
    }

    func clearConversation() {
        cancelStream()
        AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
        let ids = conversations.map(\.id)
        let storage = chatStorage
        Task { for id in ids { await storage.delete(id) } }
        conversations.removeAll()
        messages.removeAll()
        activeConversationID = nil
        clearError()
    }

    func deleteConversation(_ id: UUID) {
        if activeConversationID == id {
            AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
        }
        Task { await chatStorage.delete(id) }
        conversations.removeAll { $0.id == id }
        if activeConversationID == id {
            activeConversationID = nil
            messages.removeAll()
        }
    }

    /// Writes the transcript under the conversation this session already holds.
    ///
    /// The id is matched against storage rather than against the in-memory list. A session holding
    /// an id the list had not caught up with took the new-conversation branch, orphaning the
    /// transcript the user was reading and starting a second one beside it.
    func persistCurrentConversation() {
        guard !messages.isEmpty else { return }
        let wireMessages = messages.map { $0.wireSnapshot }

        if let existingID = activeConversationID {
            var conversation = conversations.first(where: { $0.id == existingID })
                ?? AIConversation(id: existingID, connectionId: connection?.id, connectionName: connection?.name)
            conversation.messages = wireMessages
            conversation.updatedAt = Date()
            conversation.updateTitle()
            conversation.connectionName = connection?.name
            Task { await chatStorage.save(conversation) }

            if let index = conversations.firstIndex(where: { $0.id == existingID }) {
                conversations[index] = conversation
            } else {
                conversations.insert(conversation, at: 0)
            }
            return
        }

        var conversation = AIConversation(
            messages: wireMessages,
            connectionId: connection?.id,
            connectionName: connection?.name
        )
        conversation.updateTitle()
        Task { await chatStorage.save(conversation) }
        activeConversationID = conversation.id
        conversations.insert(conversation, at: 0)
    }
}
