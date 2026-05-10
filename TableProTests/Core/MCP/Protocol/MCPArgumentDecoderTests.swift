import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP Argument Decoder")
struct MCPArgumentDecoderTests {
    @Test("requireString returns string when present")
    func requireStringPresent() throws {
        let args: JsonValue = .object(["name": .string("hello")])
        let value = try MCPArgumentDecoder.requireString(args, key: "name")
        #expect(value == "hello")
    }

    @Test("requireString throws when missing")
    func requireStringMissing() {
        let args: JsonValue = .object([:])
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPArgumentDecoder.requireString(args, key: "name")
        }
    }

    @Test("requireString throws when wrong type")
    func requireStringWrongType() {
        let args: JsonValue = .object(["name": .int(5)])
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPArgumentDecoder.requireString(args, key: "name")
        }
    }

    @Test("optionalString returns nil when missing")
    func optionalStringMissing() {
        let args: JsonValue = .object([:])
        let value = MCPArgumentDecoder.optionalString(args, key: "name")
        #expect(value == nil)
    }

    @Test("optionalString returns value when present")
    func optionalStringPresent() {
        let args: JsonValue = .object(["name": .string("foo")])
        let value = MCPArgumentDecoder.optionalString(args, key: "name")
        #expect(value == "foo")
    }

    @Test("requireUuid parses a valid UUID string")
    func requireUuidValid() throws {
        let id = UUID()
        let args: JsonValue = .object(["connection_id": .string(id.uuidString)])
        let value = try MCPArgumentDecoder.requireUuid(args, key: "connection_id")
        #expect(value == id)
    }

    @Test("requireUuid throws on malformed string")
    func requireUuidInvalid() {
        let args: JsonValue = .object(["connection_id": .string("not-a-uuid")])
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPArgumentDecoder.requireUuid(args, key: "connection_id")
        }
    }

    @Test("requireUuid throws when missing")
    func requireUuidMissing() {
        let args: JsonValue = .object([:])
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPArgumentDecoder.requireUuid(args, key: "connection_id")
        }
    }

    @Test("optionalUuid returns nil when missing")
    func optionalUuidMissing() throws {
        let args: JsonValue = .object([:])
        let value = try MCPArgumentDecoder.optionalUuid(args, key: "connection_id")
        #expect(value == nil)
    }

    @Test("optionalUuid throws on invalid value")
    func optionalUuidInvalid() {
        let args: JsonValue = .object(["connection_id": .string("bad")])
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPArgumentDecoder.optionalUuid(args, key: "connection_id")
        }
    }

    @Test("requireInt returns value")
    func requireIntPresent() throws {
        let args: JsonValue = .object(["count": .int(7)])
        let value = try MCPArgumentDecoder.requireInt(args, key: "count")
        #expect(value == 7)
    }

    @Test("requireInt throws when missing")
    func requireIntMissing() {
        let args: JsonValue = .object([:])
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPArgumentDecoder.requireInt(args, key: "count")
        }
    }

    @Test("optionalInt returns default when missing")
    func optionalIntMissing() {
        let args: JsonValue = .object([:])
        let value = MCPArgumentDecoder.optionalInt(args, key: "count", default: 42)
        #expect(value == 42)
    }

    @Test("optionalInt clamps within range")
    func optionalIntClamps() {
        let args: JsonValue = .object(["count": .int(1_000)])
        let value = MCPArgumentDecoder.optionalInt(args, key: "count", default: nil, clamp: 1...100)
        #expect(value == 100)
    }

    @Test("optionalInt clamps lower bound")
    func optionalIntClampLower() {
        let args: JsonValue = .object(["count": .int(-5)])
        let value = MCPArgumentDecoder.optionalInt(args, key: "count", default: nil, clamp: 1...100)
        #expect(value == 1)
    }

    @Test("optionalInt returns default when missing without clamp")
    func optionalIntDefault() {
        let args: JsonValue = .object([:])
        let value = MCPArgumentDecoder.optionalInt(args, key: "count", default: 5)
        #expect(value == 5)
    }

    @Test("optionalBool returns default when missing")
    func optionalBoolDefault() {
        let args: JsonValue = .object([:])
        #expect(MCPArgumentDecoder.optionalBool(args, key: "flag", default: true))
        #expect(!MCPArgumentDecoder.optionalBool(args, key: "flag", default: false))
    }

    @Test("optionalBool returns value when present")
    func optionalBoolPresent() {
        let args: JsonValue = .object(["flag": .bool(true)])
        #expect(MCPArgumentDecoder.optionalBool(args, key: "flag", default: false))
    }

    @Test("optionalDouble returns int as double")
    func optionalDoubleFromInt() {
        let args: JsonValue = .object(["value": .int(3)])
        #expect(MCPArgumentDecoder.optionalDouble(args, key: "value") == 3.0)
    }

    @Test("optionalStringArray returns nil when missing")
    func optionalStringArrayMissing() {
        let args: JsonValue = .object([:])
        let value = MCPArgumentDecoder.optionalStringArray(args, key: "tables")
        #expect(value == nil)
    }

    @Test("optionalStringArray returns nil when empty")
    func optionalStringArrayEmpty() {
        let args: JsonValue = .object(["tables": .array([])])
        let value = MCPArgumentDecoder.optionalStringArray(args, key: "tables")
        #expect(value == nil)
    }

    @Test("optionalStringArray collects strings")
    func optionalStringArrayCollects() {
        let args: JsonValue = .object([
            "tables": .array([.string("a"), .string("b"), .int(3)])
        ])
        let value = MCPArgumentDecoder.optionalStringArray(args, key: "tables")
        #expect(value == ["a", "b"])
    }
}
