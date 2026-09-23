import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB cell codec")
struct DynamoDBCellCodecTests {
    struct CellCase: Sendable, CustomTestStringConvertible {
        let name: String
        let value: DynamoDBAttributeValue
        let expected: PluginCellValue
        var testDescription: String { name }
    }

    struct TextCase: Sendable, CustomTestStringConvertible {
        let text: String
        let expected: DynamoDBAttributeValue
        var testDescription: String { text }
    }

    struct SetCase: Sendable, CustomTestStringConvertible {
        let name: String
        let template: DynamoDBAttributeValue
        let text: String
        var testDescription: String { name }
    }

    private static func decodeText(
        _ text: String,
        template: DynamoDBAttributeValue? = nil,
        columnType: DynamoDBAttributeType? = nil,
        attribute: String = "attr"
    ) throws -> DynamoDBAttributeValue? {
        try DynamoDBCellCodec.decode(.text(text), template: template, columnType: columnType, attribute: attribute)
    }

    private static func invalidValueAttribute(of error: DynamoDBError?) -> String? {
        guard case .invalidValue(let attribute, _) = error else { return nil }
        return attribute
    }

    @Test(
        "A scalar attribute becomes the cell its type reads as",
        arguments: [
            CellCase(name: "String", value: .string("02134"), expected: .text("02134")),
            CellCase(name: "Number", value: .number("1.50"), expected: .text("1.50")),
            CellCase(
                name: "38 digit Number",
                value: .number("12345678901234567890123456789012345678"),
                expected: .text("12345678901234567890123456789012345678")
            ),
            CellCase(name: "true", value: .bool(true), expected: .text("true")),
            CellCase(name: "false", value: .bool(false), expected: .text("false")),
            CellCase(name: "NULL", value: .null, expected: .null),
            CellCase(name: "Binary", value: .binary(Data([0x00, 0xFF, 0x10])), expected: .bytes(Data([0x00, 0xFF, 0x10])))
        ]
    )
    func scalarCells(cellCase: CellCase) {
        #expect(DynamoDBCellCodec.cell(for: cellCase.value) == cellCase.expected)
    }

    @Test("A missing attribute is a null cell")
    func missingAttributeIsNull() {
        #expect(DynamoDBCellCodec.cell(for: nil) == .null)
    }

    @Test("A map renders as plain JSON with sorted keys and exact numbers")
    func mapRendersAsPlainJSON() {
        let value = DynamoDBAttributeValue.map([
            "b": .number("12345678901234567890123456789012345678"),
            "a": .string("x"),
            "c": .map(["z": .bool(true), "y": .null]),
            "d": .number("1.50")
        ])
        let expected = #"{"a":"x","b":12345678901234567890123456789012345678,"c":{"y":null,"z":true},"d":1.50}"#
        #expect(DynamoDBCellCodec.cell(for: value) == .text(expected))
    }

    @Test("A list renders its elements in order, with binary as base64")
    func listRendersInOrder() {
        let value = DynamoDBAttributeValue.list([.string("x"), .number("1.50"), .binary(Data([0xFF])), .null])
        #expect(DynamoDBCellCodec.cell(for: value) == .text(#"["x",1.50,"/w==",null]"#))
    }

    @Test("A String Set renders its members sorted")
    func stringSetRendersSorted() {
        #expect(DynamoDBCellCodec.cell(for: .stringSet(["b", "a", "c"])) == .text(#"["a","b","c"]"#))
    }

    @Test("A Number Set renders its members in numeric order")
    func numberSetRendersNumerically() {
        let value = DynamoDBAttributeValue.numberSet(["10", "9", "-1", "1.5", "1e3"])
        #expect(DynamoDBCellCodec.cell(for: value) == .text("[-1,1.5,9,10,1e3]"))
    }

    @Test("A Binary Set renders its members as sorted base64")
    func binarySetRendersSortedBase64() {
        let value = DynamoDBAttributeValue.binarySet([Data([2]), Data([1])])
        #expect(DynamoDBCellCodec.cell(for: value) == .text(#"["AQ==","Ag=="]"#))
    }

    @Test("Number spellings JSON does not allow are rewritten as JSON numbers inside a map")
    func dynamoDBOnlyNumberFormsBecomeJSON() {
        let value = DynamoDBAttributeValue.map([
            "plus": .number("+5"),
            "point": .number(".5"),
            "negativePoint": .number("-.5"),
            "trailingPoint": .number("5.")
        ])
        #expect(DynamoDBCellCodec.cell(for: value) == .text(#"{"negativePoint":-0.5,"plus":5,"point":0.5,"trailingPoint":5}"#))
    }

    @Test("Every number the codec accepts renders as a number, never as null", arguments: ["007.5", "-0012", "+.5"])
    func acceptedNumbersNeverRenderAsNull(text: String) throws {
        #expect(DynamoDBNumber.isValid(text))
        guard case .text(let rendered) = DynamoDBCellCodec.cell(for: .numberSet([text])) else {
            Issue.record("A Number Set must render as text")
            return
        }
        let member = try #require(try DynamoDBJSON.parse(rendered).arrayValue?.first)
        let number = try #require(member.numberText, "rendered \(rendered)")
        #expect(DynamoDBNumber.areEqual(number, text))
    }

    @Test("Digits typed over a String stay a String")
    func stringTemplateKeepsLeadingZeros() throws {
        #expect(try Self.decodeText("02134", template: .string("x")) == .string("02134"))
    }

    @Test("A template's type wins over the column's type")
    func templateBeatsColumnType() throws {
        #expect(try Self.decodeText("02134", template: .string("x"), columnType: .number) == .string("02134"))
    }

    @Test("Digits typed over a Number become a Number with the trimmed text")
    func numberTemplateKeepsTrimmedText() throws {
        #expect(try Self.decodeText("02134", template: .number("5")) == .number("02134"))
        #expect(try Self.decodeText(" 1.50 ", template: .number("5")) == .number("1.50"))
    }

    @Test("Text that is not a number, typed over a Number, is an error naming the attribute")
    func invalidNumberNamesAttribute() {
        let error = #expect(throws: DynamoDBError.self) {
            try Self.decodeText("12abc", template: .number("5"), attribute: "price")
        }
        #expect(Self.invalidValueAttribute(of: error) == "price")
        #expect(error?.localizedDescription.contains("price") == true)
    }

    @Test("A number outside DynamoDB's range is an error")
    func outOfRangeNumberIsRejected() {
        #expect(throws: DynamoDBError.self) { try Self.decodeText("1E+126", template: .number("5")) }
        #expect(throws: DynamoDBError.self) { try Self.decodeText("1234567890123456789012345678901234567890", template: .number("5")) }
    }

    @Test("A JSON array over a String Set stays a String Set")
    func stringSetStaysStringSet() throws {
        #expect(try Self.decodeText(#"["b", "a"]"#, template: .stringSet(["x"])) == .stringSet(["b", "a"]))
    }

    @Test("A JSON array over a Number Set stays a Number Set, from numbers or numeric strings")
    func numberSetStaysNumberSet() throws {
        #expect(try Self.decodeText(#"[3, "1.5", 12345678901234567890123456789012345678]"#, template: .numberSet(["1"]))
            == .numberSet(["3", "1.5", "12345678901234567890123456789012345678"]))
    }

    @Test("A JSON array over a Binary Set stays a Binary Set")
    func binarySetStaysBinarySet() throws {
        #expect(try Self.decodeText(#"["AQ==", "AgM="]"#, template: .binarySet([Data([9])]))
            == .binarySet([Data([1]), Data([2, 3])]))
    }

    @Test("A JSON array over a List stays a List and each element keeps its own template")
    func listKeepsElementTemplates() throws {
        let template = DynamoDBAttributeValue.list([.binary(Data([9])), .stringSet(["a"]), .number("1")])
        let decoded = try Self.decodeText(#"["AQ==", ["c", "b"], 2, "extra"]"#, template: template)
        #expect(decoded == .list([.binary(Data([1])), .stringSet(["c", "b"]), .number("2"), .string("extra")]))
    }

    @Test("Editing a map as JSON keeps nested sets and binary from the template")
    func mapKeepsNestedTypes() throws {
        let template = DynamoDBAttributeValue.map([
            "tags": .numberSet(["1", "2"]),
            "names": .stringSet(["a"]),
            "blob": .binary(Data([1])),
            "zip": .string("02134"),
            "inner": .map(["hashes": .binarySet([Data([1])])])
        ])
        let text = #"{"tags":[3,1],"names":["b"],"blob":"Ag==","zip":"02134","inner":{"hashes":["AwQ="]},"new":"z"}"#
        let decoded = try Self.decodeText(text, template: template)
        #expect(decoded == .map([
            "tags": .numberSet(["3", "1"]),
            "names": .stringSet(["b"]),
            "blob": .binary(Data([2])),
            "zip": .string("02134"),
            "inner": .map(["hashes": .binarySet([Data([3, 4])])]),
            "new": .string("z")
        ]))
    }

    @Test("An unedited cell decodes back to the value it was rendered from")
    func renderedCellRoundTrips() throws {
        let value = DynamoDBAttributeValue.map([
            "s": .string("02134"),
            "n": .number("12345678901234567890123456789012345678"),
            "scaled": .number("1.50"),
            "b": .binary(Data([1, 2])),
            "t": .bool(true),
            "z": .null,
            "l": .list([.string("x"), .number("1.5"), .binary(Data([7]))]),
            "m": .map(["inner": .numberSet(["1", "2"])]),
            "ss": .stringSet(["a", "b"]),
            "ns": .numberSet(["-1", "10"]),
            "bs": .binarySet([Data([1]), Data([2])])
        ])
        guard case .text(let text) = DynamoDBCellCodec.cell(for: value) else {
            Issue.record("A map must render as text")
            return
        }
        #expect(try Self.decodeText(text, template: value) == value)
    }

    @Test("Map text that is not JSON is an error naming the attribute")
    func invalidMapJSONNamesAttribute() {
        let error = #expect(throws: DynamoDBError.self) {
            try Self.decodeText(#"{"a": "#, template: .map(["a": .string("x")]), attribute: "profile")
        }
        #expect(Self.invalidValueAttribute(of: error) == "profile")
    }

    @Test(
        "An empty set is an error",
        arguments: [
            SetCase(name: "String Set", template: .stringSet(["a"]), text: "[]"),
            SetCase(name: "Number Set", template: .numberSet(["1"]), text: "[]"),
            SetCase(name: "Binary Set", template: .binarySet([Data([1])]), text: " [ ] ")
        ]
    )
    func emptySetIsRejected(setCase: SetCase) {
        #expect(throws: DynamoDBError.self) { try Self.decodeText(setCase.text, template: setCase.template) }
    }

    @Test(
        "A set holding the same member twice is an error",
        arguments: [
            SetCase(name: "String Set", template: .stringSet(["a"]), text: #"["a", "b", "a"]"#),
            SetCase(name: "Number Set as numbers", template: .numberSet(["1"]), text: "[1, 1.0]"),
            SetCase(name: "Number Set as strings", template: .numberSet(["1"]), text: #"["1", "1.0"]"#),
            SetCase(name: "Number Set in exponent form", template: .numberSet(["1"]), text: "[100, 1e2]"),
            SetCase(name: "Binary Set", template: .binarySet([Data([1])]), text: #"["AQ==", "AQ=="]"#)
        ]
    )
    func duplicateSetMemberIsRejected(setCase: SetCase) {
        #expect(throws: DynamoDBError.self) { try Self.decodeText(setCase.text, template: setCase.template) }
    }

    @Test("String Set members DynamoDB stores as different bytes are not duplicates")
    func canonicallyEquivalentStringsAreDistinctMembers() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let text = DynamoDBJSON.array([.string(composed), .string(decomposed)]).serialized()
        let decoded = try Self.decodeText(text, template: .stringSet(["x"]))
        guard case .stringSet(let members) = decoded else {
            Issue.record("Expected a String Set, got \(String(describing: decoded))")
            return
        }
        #expect(members.map { Array($0.utf8) } == [Array(composed.utf8), Array(decomposed.utf8)])
    }

    @Test(
        "Boolean text decodes over a Boolean",
        arguments: [
            TextCase(text: "true", expected: .bool(true)),
            TextCase(text: "1", expected: .bool(true)),
            TextCase(text: " TRUE ", expected: .bool(true)),
            TextCase(text: "false", expected: .bool(false)),
            TextCase(text: "0", expected: .bool(false)),
            TextCase(text: "False", expected: .bool(false))
        ]
    )
    func booleanText(textCase: TextCase) throws {
        #expect(try Self.decodeText(textCase.text, template: .bool(false)) == textCase.expected)
    }

    @Test("Text that is not a boolean is an error over a Boolean", arguments: ["yes", "", "2", "truthy"])
    func invalidBooleanIsRejected(text: String) {
        let error = #expect(throws: DynamoDBError.self) {
            try Self.decodeText(text, template: .bool(true), attribute: "active")
        }
        #expect(Self.invalidValueAttribute(of: error) == "active")
    }

    @Test("Empty or null text over a NULL stays NULL", arguments: ["", "  ", "null", "NULL"])
    func nullTemplateKeepsNull(text: String) throws {
        #expect(try Self.decodeText(text, template: .null) == .null)
    }

    @Test("Other text over a NULL is read as if the attribute had no type")
    func nullTemplateInfersOtherText() throws {
        #expect(try Self.decodeText("02134", template: .null) == .string("02134"))
        #expect(try Self.decodeText(#"{"a": 1}"#, template: .null) == .map(["a": .number("1")]))
    }

    @Test("Base64 text over a Binary decodes to its bytes, and other text is an error")
    func binaryTemplateDecodesBase64() throws {
        #expect(try Self.decodeText(" AQID\n", template: .binary(Data([9]))) == .binary(Data([1, 2, 3])))
        #expect(throws: DynamoDBError.self) { try Self.decodeText("not base64!", template: .binary(Data([9]))) }
    }

    @Test("A bytes cell is Binary whatever the template")
    func bytesCellIsBinary() throws {
        let decoded = try DynamoDBCellCodec.decode(
            .bytes(Data([1, 2])), template: .string("x"), columnType: .string, attribute: "attr"
        )
        #expect(decoded == .binary(Data([1, 2])))
    }

    @Test("A null cell removes the attribute")
    func nullCellRemovesAttribute() throws {
        let decoded = try DynamoDBCellCodec.decode(.null, template: .string("x"), columnType: .string, attribute: "attr")
        #expect(decoded == nil)
    }

    @Test(
        "With no template and no column type, text is a String unless it is a JSON object or array",
        arguments: [
            TextCase(text: "hello", expected: .string("hello")),
            TextCase(text: "02134", expected: .string("02134")),
            TextCase(text: "true", expected: .string("true")),
            TextCase(text: "{oops", expected: .string("{oops")),
            TextCase(text: #"{"a": 1, "b": {"c": "d"}}"#, expected: .map(["a": .number("1"), "b": .map(["c": .string("d")])])),
            TextCase(text: #"[1, "x", true, null]"#, expected: .list([.number("1"), .string("x"), .bool(true), .null])),
            TextCase(text: "  []  ", expected: .list([]))
        ]
    )
    func inferredWithoutTemplate(textCase: TextCase) throws {
        #expect(try Self.decodeText(textCase.text) == textCase.expected)
    }

    @Test("A Number column types new text as a Number")
    func numberColumnTypeDecodesNumber() throws {
        #expect(try Self.decodeText("12", columnType: .number) == .number("12"))
        #expect(throws: DynamoDBError.self) { try Self.decodeText("twelve", columnType: .number) }
    }

    @Test("A set or map column types new JSON text as that type")
    func collectionColumnTypes() throws {
        #expect(try Self.decodeText(#"["a", "b"]"#, columnType: .stringSet) == .stringSet(["a", "b"]))
        #expect(try Self.decodeText("[1, 2]", columnType: .numberSet) == .numberSet(["1", "2"]))
        #expect(try Self.decodeText(#"{"a": [1]}"#, columnType: .map) == .map(["a": .list([.number("1")])]))
        #expect(try Self.decodeText("[1]", columnType: .list) == .list([.number("1")]))
    }

    @Test("Text that is not JSON is an error in a Map column")
    func nonJSONInMapColumnIsRejected() {
        #expect(throws: DynamoDBError.self) { try Self.decodeText("hello", columnType: .map) }
    }
}
