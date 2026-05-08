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
        let args: JsonValue = .object(["name": .string("alpha")])
        #expect(try ChatToolArgumentDecoder.requireString(args, key: "name") == "alpha")
    }

    @Test("requireString throws when key is missing")
    func requireStringMissing() {
        let args: JsonValue = .object([:])
        #expect(throws: ChatToolArgumentError.self) {
            _ = try ChatToolArgumentDecoder.requireString(args, key: "name")
        }
    }

    @Test("requireString throws when value is not a string")
    func requireStringWrongType() {
        let args: JsonValue = .object(["count": .int(42)])
        #expect(throws: ChatToolArgumentError.self) {
            _ = try ChatToolArgumentDecoder.requireString(args, key: "count")
        }
    }

    @Test("optionalString returns nil for missing key")
    func optionalStringMissing() {
        let args: JsonValue = .object([:])
        #expect(ChatToolArgumentDecoder.optionalString(args, key: "name") == nil)
    }

    @Test("requireUUID parses a valid UUID string")
    func requireUUIDValid() throws {
        let id = UUID()
        let args: JsonValue = .object(["connection_id": .string(id.uuidString)])
        #expect(try ChatToolArgumentDecoder.requireUUID(args, key: "connection_id") == id)
    }

    @Test("requireUUID throws for malformed UUID string")
    func requireUUIDInvalid() {
        let args: JsonValue = .object(["connection_id": .string("not-a-uuid")])
        #expect(throws: ChatToolArgumentError.self) {
            _ = try ChatToolArgumentDecoder.requireUUID(args, key: "connection_id")
        }
    }

    @Test("optionalBool returns the default when key missing")
    func optionalBoolDefault() {
        let args: JsonValue = .object([:])
        #expect(ChatToolArgumentDecoder.optionalBool(args, key: "enabled", default: true) == true)
        #expect(ChatToolArgumentDecoder.optionalBool(args, key: "enabled", default: false) == false)
    }

    @Test("optionalBool returns the value when present")
    func optionalBoolPresent() {
        let args: JsonValue = .object(["enabled": .bool(false)])
        #expect(ChatToolArgumentDecoder.optionalBool(args, key: "enabled", default: true) == false)
    }

    @Test("optionalInt returns fallback when key is missing")
    func optionalIntMissing() {
        let args: JsonValue = .object([:])
        #expect(ChatToolArgumentDecoder.optionalInt(args, key: "max_rows", default: 500) == 500)
    }

    @Test("optionalInt accepts integer values")
    func optionalIntInteger() {
        let args: JsonValue = .object(["max_rows": .int(120)])
        #expect(ChatToolArgumentDecoder.optionalInt(args, key: "max_rows", default: 500) == 120)
    }

    @Test("optionalInt coerces number (Double) to Int")
    func optionalIntFromDouble() {
        let args: JsonValue = .object(["max_rows": .double(120.7)])
        #expect(ChatToolArgumentDecoder.optionalInt(args, key: "max_rows", default: 500) == 120)
    }

    @Test("optionalInt clamps to the supplied range")
    func optionalIntClamps() {
        let args: JsonValue = .object(["max_rows": .int(50_000)])
        #expect(
            ChatToolArgumentDecoder.optionalInt(args, key: "max_rows", default: 500, clamp: 1...10_000)
            == 10_000
        )
    }

    @Test("optionalInt returns fallback for non-numeric value")
    func optionalIntWrongType() {
        let args: JsonValue = .object(["max_rows": .string("ten")])
        #expect(ChatToolArgumentDecoder.optionalInt(args, key: "max_rows", default: 500) == 500)
    }
}
