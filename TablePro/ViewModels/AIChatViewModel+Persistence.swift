//
//  AIChatViewModel+Persistence.swift
//  TablePro
//

import Foundation

extension AIChatViewModel {
    /// Lists what this session may switch to, and adopts none of it.
    ///
    /// This used to load every conversation in the app and adopt the most recent one whenever
    /// `messages` was empty, so every session created after the first inherited another
    /// connection's transcript and then persisted over it under the same id.
    ///
    /// Called by the chat surface rather than by `init`. Every read walks the whole conversation
    /// directory and decodes each file, so doing it at construction made restoring N sessions at
    /// launch N directory scans for a list only the visible session's history menu ever shows.
    func loadConversations() {
        let storage = chatStorage
        let scope = connection?.id
        Task.detached(priority: .utility) { [weak self] in
            let loaded = await storage.loadAll(connectionId: scope)
            await MainActor.run {
                self?.conversations = loaded
            }
        }
    }

    /// Clears this session only. It used to call `deleteAll`, which erased every conversation in
    /// the app from a control that names one.
    func clearConversation() {
        cancelStream()
        resetProviderConversation()
        if let activeConversationID {
            let id = activeConversationID
            Task { await chatStorage.delete(id) }
            conversations.removeAll { $0.id == id }
        }
        messages.removeAll()
        activeConversationID = nil
        clearError()
    }

    /// Pulls one conversation in by id, without listing the rest.
    ///
    /// This is how a restored session gets its turns: `switchConversation` can only pick from
    /// `conversations`, which is populated by a full directory scan the restored session has no
    /// reason to pay for. An id that no longer names a file leaves the session empty rather than
    /// adopting whatever the most recent conversation happens to be.
    func adoptConversation(id: UUID) async {
        guard let conversation = await chatStorage.load(id: id) else { return }
        messages = conversation.messages.map { ChatTurn(wire: $0) }
        activeConversationID = conversation.id
    }

    func deleteConversation(_ id: UUID) {
        if activeConversationID == id {
            resetProviderConversation()
        }
        Task { await chatStorage.delete(id) }
        conversations.removeAll { $0.id == id }
        if activeConversationID == id {
            activeConversationID = nil
            messages.removeAll()
        }
    }

    /// Quit only. The ordinary path hands the write to the storage actor, which at terminate may
    /// never be scheduled, so a session killed mid-stream came back with its last turn missing.
    func persistCurrentConversationSync() {
        guard let conversation = snapshotCurrentConversation() else { return }
        chatStorage.saveSync(conversation)
    }

    func persistCurrentConversation() {
        guard let conversation = snapshotCurrentConversation() else { return }
        Task { await chatStorage.save(conversation) }
        activeConversationID = conversation.id
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
    }

    /// The record this session would write, or nil when there is nothing to write.
    ///
    /// The update arm keys on `activeConversationID` alone, not on finding that id in
    /// `conversations`. That list is populated by a directory scan the chat surface runs, and a
    /// restored session holds its conversation id without having run one, so requiring the list
    /// would send every restored session down the new-conversation arm: the transcript the user was
    /// reading orphaned, and a second one started beside it under a new id.
    private func snapshotCurrentConversation() -> AIConversation? {
        guard !messages.isEmpty else { return nil }
        session?.adoptTitleFromTranscript()
        let wireMessages = messages.map { $0.wireSnapshot }
        var conversation = conversations.first { $0.id == activeConversationID }
            ?? AIConversation(id: activeConversationID ?? UUID())
        conversation.messages = wireMessages
        conversation.updatedAt = Date()
        conversation.updateTitle()
        conversation.connectionId = connection?.id ?? conversation.connectionId
        conversation.connectionName = connection?.name ?? conversation.connectionName
        return conversation
    }
}
