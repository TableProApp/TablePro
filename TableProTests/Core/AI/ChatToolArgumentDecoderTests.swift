//
//  ChatToolArgumentDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatToolArgumentDecoder")
struct ChatToolArgumentDecoderTests {
    @Test("requireString returns value when key exists and is a string")
    func requireStringPresent() throws {
        let args: JSONValue = .object(["name": .string("alpha")])
        #expect(try ChatToolArgumentDecoder.requireString(args, key: "name") == "alpha")
    }

    @Test("requireString throws when key is missing")
    func requireStringMissing() {
        let args: JSONValue = .object([:])
        #expect(throws: ChatToolArgumentError.self) {
            _ = try ChatToolArgumentDecoder.requireString(args, key: "name")
        }
    }

    @Test("requireString throws when value is not a string")
    func requireStringWrongType() {
        let args: JSONValue = .object(["count": .integer(42)])
        #expect(throws: ChatToolArgumentError.self) {
            _ = try ChatToolArgumentDecoder.requireString(args, key: "count")
        }
    }

    @Test("optionalString returns nil for missing key")
    func optionalStringMissing() {
        let args: JSONValue = .object([:])
        #expect(ChatToolArgumentDecoder.optionalString(args, key: "name") == nil)
    }

    @Test("requireUUID parses a valid UUID string")
    func requireUUIDValid() throws {
        let id = UUID()
        let args: JSONValue = .object(["connection_id": .string(id.uuidString)])
        #expect(try ChatToolArgumentDecoder.requireUUID(args, key: "connection_id") == id)
    }

    @Test("requireUUID throws for malformed UUID string")
    func requireUUIDInvalid() {
        let args: JSONValue = .object(["connection_id": .string("not-a-uuid")])
        #expect(throws: ChatToolArgumentError.self) {
            _ = try ChatToolArgumentDecoder.requireUUID(args, key: "connection_id")
        }
    }

    @Test("optionalBool returns the default when key missing")
    func optionalBoolDefault() {
        let args: JSONValue = .object([:])
        #expect(ChatToolArgumentDecoder.optionalBool(args, key: "enabled", default: true) == true)
        #expect(ChatToolArgumentDecoder.optionalBool(args, key: "enabled", default: false) == false)
    }

    @Test("optionalBool returns the value when present")
    func optionalBoolPresent() {
        let args: JSONValue = .object(["enabled": .bool(false)])
        #expect(ChatToolArgumentDecoder.optionalBool(args, key: "enabled", default: true) == false)
    }
}
