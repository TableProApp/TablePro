//
//  ContextItemSavedQueryCodableTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ContextItem.savedQuery Codable migration")
struct ContextItemSavedQueryCodableTests {
    @Test("Decodes legacy payload missing the name field")
    func decodesLegacyMissingName() throws {
        let id = UUID()
        let json = #"{"kind":"savedQuery","id":"\#(id.uuidString)"}"#
        let item = try JSONDecoder().decode(ContextItem.self, from: Data(json.utf8))
        guard case .savedQuery(let decodedId, let name) = item else {
            Issue.record("Expected .savedQuery; got \(item)")
            return
        }
        #expect(decodedId == id)
        #expect(name == "")
    }

    @Test("Decodes new payload with name")
    func decodesNewWithName() throws {
        let id = UUID()
        let json = #"{"kind":"savedQuery","id":"\#(id.uuidString)","name":"Top Customers"}"#
        let item = try JSONDecoder().decode(ContextItem.self, from: Data(json.utf8))
        guard case .savedQuery(let decodedId, let name) = item else {
            Issue.record("Expected .savedQuery; got \(item)")
            return
        }
        #expect(decodedId == id)
        #expect(name == "Top Customers")
    }

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let id = UUID()
        let original = ContextItem.savedQuery(id: id, name: "Audit Log")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContextItem.self, from: data)
        #expect(decoded == original)
    }
}
