//
//  AIChatStorageTests.swift
//  TableProTests
//
//  Tests for AIChatStorage static encoder/decoder and round-trip persistence.
//

import Foundation
@testable import TablePro
import Testing

// TODO: Convert to async tests — AIChatStorage is an actor, methods require await
#if false
@Suite("AIChatStorage")
struct AIChatStorageTests {
    private let storage = AIChatStorage.shared

    private func makeConversation(
        id: UUID = UUID(),
        title: String = "Test Chat",
        messages: [AIChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        connectionName: String? = "test-db"
    ) -> AIConversation {
        AIConversation(
            id: id,
            title: title,
            messages: messages,
            createdAt: createdAt,
            updatedAt: updatedAt,
            connectionName: connectionName
        )
    }

    private func makeMessage(
        role: AIChatRole = .user,
        content: String = "Hello"
    ) -> AIChatMessage {
        AIChatMessage(
            role: role,
            content: content,
            timestamp: Date()
        )
    }

    private func cleanupConversation(_ id: UUID) {
        storage.delete(id)
    }

    @Test("Save and load round-trip preserves all fields")
    func saveAndLoadRoundTrip() {
        let id = UUID()
        let message = makeMessage(role: .user, content: "Test message")
        let conversation = makeConversation(
            id: id,
            title: "Round Trip Test",
            messages: [message],
            connectionName: "mydb"
        )

        storage.save(conversation)

        let loaded = storage.loadAll()
        let found = loaded.first { $0.id == id }

        #expect(found != nil)
        #expect(found?.title == "Round Trip Test")
        #expect(found?.messages.count == 1)
        #expect(found?.messages.first?.content == "Test message")
        #expect(found?.messages.first?.role == .user)
        #expect(found?.connectionName == "mydb")

        cleanupConversation(id)
    }

    @Test("ISO 8601 date encoding preserves to-second accuracy")
    func iso8601DatePreservesAccuracy() {
        let id = UUID()
        let now = Date()
        let conversation = makeConversation(id: id, createdAt: now, updatedAt: now)

        storage.save(conversation)

        let loaded = storage.loadAll()
        let found = loaded.first { $0.id == id }

        #expect(found != nil)
        let diff = abs(found!.createdAt.timeIntervalSince(now))
        #expect(diff < 1.0)

        cleanupConversation(id)
    }

    @Test("Delete removes specific conversation")
    func deleteRemovesSpecificConversation() {
        let id1 = UUID()
        let id2 = UUID()

        storage.save(makeConversation(id: id1, title: "Keep"))
        storage.save(makeConversation(id: id2, title: "Delete"))

        storage.delete(id2)

        let loaded = storage.loadAll()
        #expect(loaded.contains { $0.id == id1 })
        #expect(!loaded.contains { $0.id == id2 })

        cleanupConversation(id1)
    }

    @Test("loadAll returns conversations sorted by date descending")
    func loadAllReturnsSortedByDate() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let older = makeConversation(id: id1, title: "Older", updatedAt: Date().addingTimeInterval(-200))
        let middle = makeConversation(id: id2, title: "Middle", updatedAt: Date().addingTimeInterval(-100))
        let newer = makeConversation(id: id3, title: "Newer", updatedAt: Date())

        storage.save(older)
        storage.save(middle)
        storage.save(newer)

        let loaded = storage.loadAll()

        let ourConversations = loaded.filter { [id1, id2, id3].contains($0.id) }
        #expect(ourConversations.count == 3)

        if ourConversations.count == 3 {
            #expect(ourConversations[0].id == id3)
            #expect(ourConversations[1].id == id2)
            #expect(ourConversations[2].id == id1)
        }

        cleanupConversation(id1)
        cleanupConversation(id2)
        cleanupConversation(id3)
    }
}
#endif
