import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB attribute value")
struct DynamoDBAttributeValueTests {
    struct ValueCase: Sendable, CustomTestStringConvertible {
        let name: String
        let value: DynamoDBAttributeValue
        let wire: String
        var testDescription: String { name }
    }

    struct PayloadCase: Sendable, CustomTestStringConvertible {
        let name: String
        let wire: String
        var testDescription: String { name }
    }

    static let valueCases: [ValueCase] = [
        ValueCase(name: "String", value: .string("02134"), wire: #"{"S":"02134"}"#),
        ValueCase(
            name: "Number",
            value: .number("12345678901234567890123456789012345678"),
            wire: #"{"N":"12345678901234567890123456789012345678"}"#
        ),
        ValueCase(name: "Number with scale", value: .number("1.50"), wire: #"{"N":"1.50"}"#),
        ValueCase(name: "Binary", value: .binary(Data([1, 2, 3])), wire: #"{"B":"AQID"}"#),
        ValueCase(name: "Boolean", value: .bool(false), wire: #"{"BOOL":false}"#),
        ValueCase(name: "Null", value: .null, wire: #"{"NULL":true}"#),
        ValueCase(
            name: "List",
            value: .list([.string("x"), .number("1"), .list([]), .null]),
            wire: #"{"L":[{"S":"x"},{"N":"1"},{"L":[]},{"NULL":true}]}"#
        ),
        ValueCase(
            name: "Map",
            value: .map(["b": .bool(true), "a": .map(["n": .number("-0.5")])]),
            wire: #"{"M":{"a":{"M":{"n":{"N":"-0.5"}}},"b":{"BOOL":true}}}"#
        ),
        ValueCase(name: "String Set", value: .stringSet(["b", "a"]), wire: #"{"SS":["b","a"]}"#),
        ValueCase(name: "Number Set", value: .numberSet(["10", "1.5"]), wire: #"{"NS":["10","1.5"]}"#),
        ValueCase(name: "Binary Set", value: .binarySet([Data([2]), Data([1])]), wire: #"{"BS":["Ag==","AQ=="]}"#)
    ]

    @Test("Every type round-trips through its wire form", arguments: valueCases)
    func wireRoundTrip(valueCase: ValueCase) throws {
        #expect(try DynamoDBAttributeValue(wireJSON: valueCase.value.wireJSON) == valueCase.value)
    }

    @Test("Every type writes the wire JSON DynamoDB expects", arguments: valueCases)
    func wireText(valueCase: ValueCase) {
        #expect(valueCase.value.wireJSON.serialized() == valueCase.wire)
    }

    @Test("Every type decodes from the wire JSON DynamoDB sends", arguments: valueCases)
    func decodesWireText(valueCase: ValueCase) throws {
        #expect(try DynamoDBAttributeValue(wireJSON: DynamoDBJSON.parse(valueCase.wire)) == valueCase.value)
    }

    @Test("A value reports its own type", arguments: valueCases)
    func reportsType(valueCase: ValueCase) throws {
        let json = try DynamoDBJSON.parse(valueCase.wire)
        let tag = try #require(json.objectValue?.keys.first)
        #expect(valueCase.value.type.rawValue == tag)
    }

    @Test("A Number keeps its exact text on the wire, never passing through a Double")
    func numberStaysText() throws {
        let value = try DynamoDBAttributeValue(wireJSON: DynamoDBJSON.parse(#"{"N":"0.1000000000000000000000000000000000001"}"#))
        #expect(value == .number("0.1000000000000000000000000000000000001"))
        #expect(value.wireJSON == .object(["N": .string("0.1000000000000000000000000000000000001")]))
    }

    @Test(
        "A payload of the wrong shape is rejected",
        arguments: [
            PayloadCase(name: "String holding a number", wire: #"{"S":5}"#),
            PayloadCase(name: "Number holding a bare number", wire: #"{"N":5}"#),
            PayloadCase(name: "Binary that is not base64", wire: #"{"B":"not base64!"}"#),
            PayloadCase(name: "Boolean holding a string", wire: #"{"BOOL":"true"}"#),
            PayloadCase(name: "Null holding a string", wire: #"{"NULL":"x"}"#),
            PayloadCase(name: "List holding an object", wire: #"{"L":{}}"#),
            PayloadCase(name: "List element without a type", wire: #"{"L":["x"]}"#),
            PayloadCase(name: "Map holding an array", wire: #"{"M":[]}"#),
            PayloadCase(name: "Map entry without a type", wire: #"{"M":{"a":"x"}}"#),
            PayloadCase(name: "String Set member that is a number", wire: #"{"SS":[1]}"#),
            PayloadCase(name: "Number Set member that is a bare number", wire: #"{"NS":[1]}"#),
            PayloadCase(name: "Binary Set member that is not base64", wire: #"{"BS":["!!"]}"#),
            PayloadCase(name: "String Set that is not an array", wire: #"{"SS":"a"}"#)
        ]
    )
    func rejectsWrongShape(payload: PayloadCase) throws {
        let json = try DynamoDBJSON.parse(payload.wire)
        #expect(throws: DynamoDBError.self) { try DynamoDBAttributeValue(wireJSON: json) }
    }

    @Test(
        "A value that does not name exactly one known type is rejected",
        arguments: [
            PayloadCase(name: "unknown tag", wire: #"{"X":"a"}"#),
            PayloadCase(name: "lowercase tag", wire: #"{"s":"a"}"#),
            PayloadCase(name: "two tags", wire: #"{"S":"a","N":"1"}"#),
            PayloadCase(name: "no tag", wire: "{}"),
            PayloadCase(name: "bare string", wire: #""a""#),
            PayloadCase(name: "array", wire: #"[{"S":"a"}]"#),
            PayloadCase(name: "null", wire: "null")
        ]
    )
    func rejectsUnknownOrAmbiguousTag(payload: PayloadCase) throws {
        let json = try DynamoDBJSON.parse(payload.wire)
        #expect(throws: DynamoDBError.self) { try DynamoDBAttributeValue(wireJSON: json) }
    }

    @Test("The error for an unknown tag names the tag")
    func unknownTagIsNamed() throws {
        let json = try DynamoDBJSON.parse(#"{"XYZ":"a"}"#)
        let error = #expect(throws: DynamoDBError.self) { try DynamoDBAttributeValue(wireJSON: json) }
        #expect(error?.localizedDescription.contains("XYZ") == true)
    }

    @Test("An item round-trips through its wire form")
    func itemRoundTrip() throws {
        let item: DynamoDBItem = [
            "pk": .string("user#1"),
            "sk": .number("1700000000"),
            "balance": .number("12345678901234567890123456789012345678"),
            "avatar": .binary(Data([0xFF, 0x00])),
            "active": .bool(true),
            "nickname": .null,
            "tags": .stringSet(["a", "b"]),
            "scores": .numberSet(["1", "2.5"]),
            "keys": .binarySet([Data([1])]),
            "history": .list([.map(["at": .number("1"), "what": .string("login")])]),
            "profile": .map(["address": .map(["zip": .string("02134")])])
        ]
        #expect(try DynamoDBItem(wireItem: item.wireJSON) == item)
        #expect(try DynamoDBItem(wireItem: DynamoDBJSON.parse(item.wireJSON.serialized())) == item)
    }

    @Test("An item decodes from a GetItem response body")
    func itemFromResponse() throws {
        let response = try DynamoDBJSON.parse(#"""
        {"Item":{"pk":{"S":"a"},"n":{"N":"1.50"},"doc":{"M":{"inner":{"L":[{"BOOL":true},{"NULL":true}]}}},"blob":{"B":"AQID"}}}
        """#)
        let item = try DynamoDBItem(wireItem: try #require(response["Item"]))
        #expect(item == [
            "pk": .string("a"),
            "n": .number("1.50"),
            "doc": .map(["inner": .list([.bool(true), .null])]),
            "blob": .binary(Data([1, 2, 3]))
        ])
    }

    @Test("An empty item is an empty object on the wire")
    func emptyItem() throws {
        let item: DynamoDBItem = [:]
        #expect(item.wireJSON == .object([:]))
        #expect(try DynamoDBItem(wireItem: .object([:])).isEmpty)
    }

    @Test("An item that is not an object is rejected", arguments: [#"[]"#, #""item""#, "null", "1"])
    func itemMustBeObject(text: String) throws {
        let json = try DynamoDBJSON.parse(text)
        #expect(throws: DynamoDBError.self) { try DynamoDBItem(wireItem: json) }
    }

    @Test("An item with one malformed attribute is rejected as a whole")
    func itemWithBadAttributeIsRejected() throws {
        let json = try DynamoDBJSON.parse(#"{"pk":{"S":"a"},"bad":{"N":1}}"#)
        #expect(throws: DynamoDBError.self) { try DynamoDBItem(wireItem: json) }
    }

    @Test("A type is found by its display name or its tag, in any case")
    func typeFromDisplayName() {
        #expect(DynamoDBAttributeType(displayName: "Number Set") == .numberSet)
        #expect(DynamoDBAttributeType(displayName: "number set") == .numberSet)
        #expect(DynamoDBAttributeType(displayName: "ns") == .numberSet)
        #expect(DynamoDBAttributeType(displayName: "BOOL") == .boolean)
        #expect(DynamoDBAttributeType(displayName: "Boolean") == .boolean)
        #expect(DynamoDBAttributeType(displayName: "Float") == nil)
    }

    @Test("Only String, Number and Binary can be key types")
    func keyTypes() {
        let keyTypes = DynamoDBAttributeType.allCases.filter(\.isKeyType)
        #expect(keyTypes == [.string, .number, .binary])
    }
}
