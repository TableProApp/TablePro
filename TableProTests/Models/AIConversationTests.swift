//
//  AIConversationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIConversation")
struct AIConversationTests {
    private func makeUserTurn(_ text: String) -> ChatTurn {
        ChatTurn(role: .user, blocks: [.text(text)])
    }

    @Test("updateTitle truncates long content")
    func updateTitleTruncatesLongContent() {
        var conv = AIConversation(
            title: "",
            messages: [makeUserTurn(String(repeating: "a", count: 60))]
        )
        conv.updateTitle()
        #expect(conv.title.hasSuffix("..."))
    }

    @Test("updateTitle keeps short content")
    func updateTitleKeepsShortContent() {
        var conv = AIConversation(
            title: "",
            messages: [makeUserTurn("Short query")]
        )
        conv.updateTitle()
        #expect(conv.title == "Short query")
    }

    @Test("New conversations carry the current schema version")
    func newConversationsUseCurrentSchemaVersion() {
        let conv = AIConversation()
        #expect(conv.schemaVersion == AIConversation.currentSchemaVersion)
    }

    @Test("Decoding a legacy payload without schemaVersion upgrades to the current version")
    func decodingLegacyPayloadUpgradesVersion() throws {
        let id = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
            {
                "id": "\(id.uuidString)",
                "title": "Legacy",
                "messages": [],
                "createdAt": "\(now)",
                "updatedAt": "\(now)"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conversation = try decoder.decode(AIConversation.self, from: Data(json.utf8))
        #expect(conversation.id == id)
        #expect(conversation.schemaVersion == AIConversation.currentSchemaVersion)
    }

    @Test("Round-trip encode and decode preserves the schema version")
    func roundTripPreservesSchemaVersion() throws {
        let original = AIConversation(messages: [makeUserTurn("hi")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AIConversation.self, from: data)
        #expect(decoded.schemaVersion == AIConversation.currentSchemaVersion)
    }

    @Test("Encoded payload includes the schemaVersion field")
    func encodedPayloadIncludesSchemaVersion() throws {
        let conv = AIConversation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(conv)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let storedVersion = json?["schemaVersion"] as? Int
        #expect(storedVersion == AIConversation.currentSchemaVersion)
    }
}
