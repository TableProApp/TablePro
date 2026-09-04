//
//  AIConversationMigrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIConversation schema 2 migration")
struct AIConversationMigrationTests {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func legacyPayload(connectionName: String) -> Data {
        Data("""
        {
          "id": "\(UUID().uuidString)",
          "title": "Legacy",
          "messages": [],
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z",
          "connectionName": "\(connectionName)",
          "schemaVersion": 1
        }
        """.utf8)
    }

    @Test("A schema 1 record decodes and lands in the orphan bucket")
    func legacyRecordIsOrphan() throws {
        let decoded = try Self.decoder.decode(AIConversation.self, from: legacyPayload(connectionName: "localhost"))

        #expect(decoded.connectionId == nil)
        #expect(decoded.isOrphan)
        #expect(decoded.title == "Legacy")
        #expect(decoded.connectionName == "localhost")
    }

    @Test("A schema 1 record is never matched to a connection by name")
    func legacyRecordIsNotNameMatched() throws {
        let first = try Self.decoder.decode(AIConversation.self, from: legacyPayload(connectionName: "localhost"))
        let second = try Self.decoder.decode(AIConversation.self, from: legacyPayload(connectionName: "localhost"))

        #expect(first.connectionId == nil)
        #expect(second.connectionId == nil)
    }

    @Test("Two connections sharing a name produce records that stay distinct")
    func duplicateNamesStayDistinct() {
        let first = AIConversation(title: "a", connectionId: UUID(), connectionName: "localhost")
        let second = AIConversation(title: "b", connectionId: UUID(), connectionName: "localhost")

        #expect(first.connectionId != second.connectionId)
        #expect(first.isOrphan == false)
        #expect(second.isOrphan == false)
    }

    @Test("A record created now carries the connection id and the current schema version")
    func newRecordCarriesConnectionId() {
        let connectionId = UUID()
        let conversation = AIConversation(title: "new", connectionId: connectionId)

        #expect(conversation.connectionId == connectionId)
        #expect(conversation.isOrphan == false)
        #expect(conversation.schemaVersion == 2)
    }

    @Test("The connection id round-trips through encoding")
    func connectionIdRoundTrips() throws {
        let connectionId = UUID()
        let original = AIConversation(title: "round trip", connectionId: connectionId)

        let data = try Self.encoder.encode(original)
        let decoded = try Self.decoder.decode(AIConversation.self, from: data)

        #expect(decoded.connectionId == connectionId)
    }

    @Test("An orphan re-encodes as an orphan rather than acquiring a connection")
    func orphanStaysOrphanThroughEncoding() throws {
        let decoded = try Self.decoder.decode(AIConversation.self, from: legacyPayload(connectionName: "localhost"))

        let data = try Self.encoder.encode(decoded)
        let round = try Self.decoder.decode(AIConversation.self, from: data)

        #expect(round.isOrphan)
    }
}
