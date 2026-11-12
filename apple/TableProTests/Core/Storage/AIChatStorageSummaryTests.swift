//
//  AIChatStorageSummaryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIChatStorageSummaryTests {
    private let storage = AIChatStorage.shared

    private static func conversation(_ title: String, connectionId: UUID?, updatedAt seconds: TimeInterval) -> AIConversation {
        AIConversation(
            title: title,
            messages: [
                ChatTurnWire(role: .user, blocks: [.text(title)]),
                ChatTurnWire(role: .assistant, blocks: [.text("An answer.")])
            ],
            createdAt: Date(timeIntervalSince1970: seconds - 500),
            updatedAt: Date(timeIntervalSince1970: seconds),
            connectionId: connectionId,
            connectionName: "Shop"
        )
    }

    // A conversation stored before conversations carried a connection id is listed everywhere.
    @Test("Summaries carry the stored titles newest first, without messages, for one connection")
    func summariesAreFilteredAndOrdered() async throws {
        let connectionId = UUID()
        let older = Self.conversation("Older question", connectionId: connectionId, updatedAt: 1_000)
        let newer = Self.conversation("Newer question", connectionId: connectionId, updatedAt: 3_000)
        let legacy = Self.conversation("Legacy question", connectionId: nil, updatedAt: 2_000)
        let elsewhere = Self.conversation("Elsewhere", connectionId: UUID(), updatedAt: 4_000)
        let written = [older, newer, legacy, elsewhere]
        for conversation in written {
            await storage.save(conversation)
        }
        let ids = Set(written.map { $0.id })

        let summaries = await storage.loadSummaries(connectionId: connectionId)
        let listed = summaries.filter { ids.contains($0.id) }

        #expect(listed.map { $0.title } == ["Newer question", "Legacy question", "Older question"])
        #expect(summaries.allSatisfy { $0.messages.isEmpty })
        #expect(summaries.allSatisfy { $0.connectionId == nil || $0.connectionId == connectionId })
        let first = try #require(listed.first)
        #expect(first.id == newer.id)
        #expect(first.createdAt == newer.createdAt)
        #expect(first.updatedAt == newer.updatedAt)
        #expect(first.connectionName == "Shop")
        #expect(first.schemaVersion == AIConversation.currentSchemaVersion)

        let everywhere = await storage.loadSummaries(connectionId: nil)
        #expect(ids.isSubset(of: Set(everywhere.map { $0.id })))

        let full = await storage.load(id: newer.id)
        #expect(full?.messages.count == 2)

        for conversation in written {
            await storage.delete(conversation.id)
        }
    }
}
