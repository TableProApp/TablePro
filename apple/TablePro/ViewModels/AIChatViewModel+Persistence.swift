//
//  AIChatViewModel+Persistence.swift
//  TablePro
//

import Foundation

extension AIChatViewModel {
    // Scoped to the connection, so a second connection's window never opens holding the first one's transcript.
    func restoreConversationsIfNeeded() {
        trackTableMentions()
        // With no connection the history list would hold every connection's conversations.
        guard connection != nil, !hasRestoredConversation else { return }
        markConversationRestored()
        let storage = chatStorage
        let connectionId = connection?.id
        let wanted = conversationToRestore
        let epoch = transcriptEpoch
        let saved = lastConversationWrite
        transcriptLoad = Task(priority: .utility) { [weak self] in
            await saved?.value
            let summaries = await storage.loadSummaries(connectionId: connectionId)
            var stored: AIConversation?
            if let wanted {
                stored = await storage.load(id: wanted)
            }
            guard let self, self.transcriptEpoch == epoch else { return }
            self.conversations = Self.merge(summaries, keepingTurnsOf: self.conversations)
            guard let wanted, self.conversationToRestore == wanted else { return }
            // A message sent before the restore landed started a conversation of its own, which wins.
            guard self.messages.isEmpty, self.activeConversationID == nil else {
                self.conversationToRestore = nil
                return
            }
            let readable = stored.flatMap { AIChatStorage.isShown(conversationOf: $0.connectionId, on: connectionId) ? $0 : nil }
            self.showTranscript(readable)
        }
    }

    // An entry still carrying turns holds what disk may have trimmed, so a re-read list keeps it.
    private static func merge(_ summaries: [AIConversation], keepingTurnsOf current: [AIConversation]) -> [AIConversation] {
        let kept = current.filter { !$0.messages.isEmpty }
        guard !kept.isEmpty else { return summaries }
        let keptByID = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(summaries.map(\.id))
        return kept.filter { !listed.contains($0.id) } + summaries.map { keptByID[$0.id] ?? $0 }
    }

    func clearConversation() {
        cancelStream()
        AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
        deleteStoredConversations(conversations.map(\.id))
        conversations.removeAll()
        conversationToRestore = nil
        messages.removeAll()
        activeConversationID = nil
        clearError()
    }

    func deleteConversation(_ id: UUID) {
        if activeConversationID == id {
            AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
        }
        deleteStoredConversations([id])
        conversations.removeAll { $0.id == id }
        if conversationToRestore == id {
            conversationToRestore = nil
        }
        if activeConversationID == id {
            activeConversationID = nil
            messages.removeAll()
        }
    }

    // By id, not by the in-memory list, so an id the list has not caught up with keeps its own file.
    func persistCurrentConversation() {
        guard let conversation = snapshotCurrentConversation() else { return }
        let storage = chatStorage
        let previous = lastConversationWrite
        lastConversationWrite = Task {
            await previous?.value
            await storage.save(conversation)
        }
    }

    // Behind the saves already booked, or one landing late would bring the file back.
    func deleteStoredConversations(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let storage = chatStorage
        let previous = lastConversationWrite
        lastConversationWrite = Task {
            await previous?.value
            for id in ids {
                await storage.delete(id)
            }
        }
    }

    // Termination is the only caller.
    func persistCurrentConversationSynchronously() {
        guard let conversation = snapshotCurrentConversation() else { return }
        chatStorage.saveSynchronously(conversation)
    }

    // Returns the whole conversation to write and keeps only its summary in `conversations`.
    private func snapshotCurrentConversation() -> AIConversation? {
        guard !messages.isEmpty else { return nil }

        var conversation: AIConversation
        if let existingID = activeConversationID {
            conversation = conversations.first(where: { $0.id == existingID })
                ?? AIConversation(id: existingID, connectionId: connection?.id, connectionName: connection?.name)
            conversation.updatedAt = Date()
            conversation.connectionName = connection?.name
        } else {
            conversation = AIConversation(connectionId: connection?.id, connectionName: connection?.name)
            activeConversationID = conversation.id
            conversationToRestore = nil
        }
        conversation.messages = messages.map { $0.wireSnapshot }
        conversation.updateTitle()

        var summary = conversation
        summary.messages = []
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = summary
        } else {
            conversations.insert(summary, at: 0)
        }
        return conversation
    }
}
