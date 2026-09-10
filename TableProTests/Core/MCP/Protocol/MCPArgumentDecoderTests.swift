import Foundation
import Testing

@testable import TablePro

@Suite("MCPArgumentDecoder")
struct MCPArgumentDecoderTests {
    private func expectInvalidParams(_ body: () throws -> some Any) {
        #expect(throws: MCPProtocolError.self) { _ = try body() }
    }

    private func expectInvalidArgument(_ body: () throws -> some Any) {
        #expect(throws: MCPToolExecutionError.self) { _ = try body() }
    }

    @Test("requireObject rejects a non-object")
    func requireObjectRejectsScalar() {
        expectInvalidParams { try MCPArgumentDecoder.requireObject(.string("nope")) }
    }

    @Test("rejectUnknownKeys names every unexpected parameter")
    func rejectUnknownKeysNamesThem() {
        let args: JsonValue = .object(["known": .string("a"), "typo": .int(1), "other": .bool(true)])
        #expect(throws: MCPProtocolError.self) {
            try MCPArgumentDecoder.rejectUnknownKeys(args, allowed: ["known"])
        }
        #expect(throws: Never.self) {
            try MCPArgumentDecoder.rejectUnknownKeys(args, allowed: ["known", "typo", "other"])
        }
    }

    @Test("requireString rejects a missing value")
    func requireStringMissing() {
        expectInvalidParams { try MCPArgumentDecoder.requireString(.object([:]), key: "name") }
    }

    @Test("requireString rejects a value of the wrong type")
    func requireStringWrongType() {
        expectInvalidParams {
            try MCPArgumentDecoder.requireString(.object(["name": .int(3)]), key: "name")
        }
    }

    @Test("requireNonEmptyString rejects whitespace")
    func requireNonEmptyStringRejectsWhitespace() {
        expectInvalidArgument {
            try MCPArgumentDecoder.requireNonEmptyString(.object(["name": .string("   ")]), key: "name")
        }
    }

    @Test("optionalString returns nil when the key is missing or null")
    func optionalStringAbsent() throws {
        #expect(try MCPArgumentDecoder.optionalString(.object([:]), key: "name") == nil)
        #expect(try MCPArgumentDecoder.optionalString(.object(["name": .null]), key: "name") == nil)
    }

    @Test("optionalString rejects a value of the wrong type instead of ignoring it")
    func optionalStringWrongTypeThrows() {
        expectInvalidParams {
            try MCPArgumentDecoder.optionalString(.object(["database": .int(123)]), key: "database")
        }
    }

    @Test("optionalString returns the value when present")
    func optionalStringPresent() throws {
        let args: JsonValue = .object(["name": .string("orders")])
        #expect(try MCPArgumentDecoder.optionalString(args, key: "name") == "orders")
    }

    @Test("requireEnum accepts a listed value and refuses anything else")
    func requireEnumChecksMembership() throws {
        let good: JsonValue = .object(["format": .string("csv")])
        #expect(try MCPArgumentDecoder.requireEnum(good, key: "format", allowed: ["csv", "json"]) == "csv")
        expectInvalidArgument {
            try MCPArgumentDecoder.requireEnum(
                .object(["format": .string("xml")]),
                key: "format",
                allowed: ["csv", "json"]
            )
        }
    }

    @Test("optionalEnum returns nil when absent and refuses an unlisted value")
    func optionalEnumBehaviour() throws {
        #expect(try MCPArgumentDecoder.optionalEnum(.object([:]), key: "format", allowed: ["csv"]) == nil)
        expectInvalidArgument {
            try MCPArgumentDecoder.optionalEnum(
                .object(["format": .string("xml")]),
                key: "format",
                allowed: ["csv"]
            )
        }
    }

    @Test("requireUuid parses a valid identifier and refuses a malformed one")
    func requireUuidParses() throws {
        let id = UUID()
        let args: JsonValue = .object(["connection_id": .string(id.uuidString)])
        #expect(try MCPArgumentDecoder.requireUuid(args, key: "connection_id") == id)
        expectInvalidArgument {
            try MCPArgumentDecoder.requireUuid(.object(["connection_id": .string("nope")]), key: "connection_id")
        }
    }

    @Test("optionalUuid returns nil when absent")
    func optionalUuidAbsent() throws {
        #expect(try MCPArgumentDecoder.optionalUuid(.object([:]), key: "connection_id") == nil)
    }

    @Test("requireInt accepts an integer and an integral double")
    func requireIntAcceptsIntegralDouble() throws {
        #expect(try MCPArgumentDecoder.requireInt(.object(["limit": .int(10)]), key: "limit") == 10)
        #expect(try MCPArgumentDecoder.requireInt(.object(["limit": .double(1_000)]), key: "limit") == 1_000)
    }

    @Test("requireInt refuses a fractional number and a string")
    func requireIntRefusesNonIntegers() {
        expectInvalidParams { try MCPArgumentDecoder.requireInt(.object(["limit": .double(1.5)]), key: "limit") }
        expectInvalidParams { try MCPArgumentDecoder.requireInt(.object(["limit": .string("10")]), key: "limit") }
    }

    @Test("an out-of-range limit is reported instead of silently clamped")
    func optionalIntReportsOutOfRange() {
        expectInvalidArgument {
            try MCPArgumentDecoder.optionalInt(.object(["limit": .int(99_999)]), key: "limit", range: 1...500)
        }
    }

    @Test("optionalInt returns nil when absent and the value when in range")
    func optionalIntInRange() throws {
        #expect(try MCPArgumentDecoder.optionalInt(.object([:]), key: "limit", range: 1...500) == nil)
        #expect(try MCPArgumentDecoder.optionalInt(.object(["limit": .int(50)]), key: "limit", range: 1...500) == 50)
    }

    @Test("optionalBool falls back to the default and refuses a non-boolean")
    func optionalBoolBehaviour() throws {
        #expect(try MCPArgumentDecoder.optionalBool(.object([:]), key: "flag", default: true))
        #expect(try MCPArgumentDecoder.optionalBool(.object(["flag": .bool(false)]), key: "flag", default: true) == false)
        expectInvalidParams {
            try MCPArgumentDecoder.optionalBool(.object(["flag": .string("true")]), key: "flag", default: false)
        }
    }

    @Test("optionalDouble accepts an integer and refuses a string")
    func optionalDoubleBehaviour() throws {
        #expect(try MCPArgumentDecoder.optionalDouble(.object(["ratio": .int(2)]), key: "ratio") == 2)
        expectInvalidParams {
            try MCPArgumentDecoder.optionalDouble(.object(["ratio": .string("2")]), key: "ratio")
        }
    }

    @Test("optionalStringArray returns nil when missing and collects strings otherwise")
    func optionalStringArrayCollects() throws {
        #expect(try MCPArgumentDecoder.optionalStringArray(.object([:]), key: "tables") == nil)
        let args: JsonValue = .object(["tables": .array([.string("a"), .string("b")])])
        #expect(try MCPArgumentDecoder.optionalStringArray(args, key: "tables") == ["a", "b"])
    }

    @Test("optionalStringArray refuses a mixed array instead of dropping entries")
    func optionalStringArrayRefusesMixed() {
        let args: JsonValue = .object(["tables": .array([.string("a"), .int(3)])])
        expectInvalidParams { try MCPArgumentDecoder.optionalStringArray(args, key: "tables") }
    }

    @Test("optionalObjectArray refuses an array holding a scalar")
    func optionalObjectArrayRefusesScalar() {
        let args: JsonValue = .object(["rows": .array([.object(["a": .int(1)]), .string("x")])])
        expectInvalidParams { try MCPArgumentDecoder.optionalObjectArray(args, key: "rows") }
    }
}
