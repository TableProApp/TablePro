import Foundation
@testable import TableProNumberFormatting
import Testing

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct NumberTextTests {
    @Test func testGoldenDoubleStrings() {
        #expect(NumberText.text(for: 1_847.27) == "1847.27")
        #expect(NumberText.text(for: 0.1) == "0.1")
        #expect(NumberText.text(for: 1.0) == "1")
        #expect(NumberText.text(for: 100.0) == "100")
        #expect(NumberText.text(for: 1.0 / 3.0) == "0.3333333333333333")
        #expect(NumberText.text(for: 2.6243074014352636e-25) == "2.6243074014352636e-25")
        #expect(NumberText.text(for: -3.9192320754595876e-07) == "-3.9192320754595876e-07")
    }

    @Test func testShortestRoundTripBeatsNSNumberStringValue() {
        let value = -3.9192320754595876e-07
        #expect(Double(NSNumber(value: value).stringValue) != value)
        #expect(Double(NumberText.text(for: value)) == value)
    }

    @Test func testDecimalNumbersKeepTheirExactDigits() throws {
        for literal in ["99999999999999999999", "0.12345678901234567890123"] {
            let parsed = try JSONSerialization.jsonObject(with: Data(#"{"v": \#(literal)}"#.utf8))
            let number = try #require((parsed as? [String: Any])?["v"] as? NSNumber)
            #expect(number is NSDecimalNumber, "expected NSDecimalNumber for \(literal)")
            #expect(NumberText.text(for: number) == literal)
        }
    }

    @Test func testDecimalNumbersKeepTheirExactDigitsInNestedJson() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"big": 99999999999999999999}"#.utf8))
        let value = try #require(parsed as? [String: Any])
        #expect(NumberText.json(from: value) == #"{"big":99999999999999999999}"#)
    }

    @Test func testBooleanNumbersKeepTheNumericFormAtThisLayer() {
        #expect(NumberText.text(for: NSNumber(value: true)) == "1")
        #expect(NumberText.text(for: NSNumber(value: false)) == "0")
    }

    @Test func testBooleansStayTrueAndFalseInsideJson() {
        #expect(NumberText.json(from: ["flag": true]) == #"{"flag":true}"#)
    }

    @Test func testForwardSlashesAreNotEscaped() {
        #expect(NumberText.json(from: ["topic": "device/state/up/122"]) == #"{"topic":"device/state/up/122"}"#)
    }

    @Test func testForwardSlashesStayUnescapedInsideNestedValues() {
        let value: [String: Any] = ["destinations": [["topic": "device/state/up/122"]]]
        #expect(NumberText.json(from: value) == #"{"destinations":[{"topic":"device/state/up/122"}]}"#)
    }

    @Test func testBackslashesAreStillEscaped() {
        #expect(NumberText.json(from: ["path": #"a\b"#]) == #"{"path":"a\\b"}"#)
    }

    @Test func testPrettyPrintedJsonUsesTheSameNumbers() {
        let json = NumberText.json(from: ["rate": 0.1], prettyPrinted: true)
        #expect(json?.contains("0.1") == true)
        #expect(json?.contains("0.10000000000000001") == false)
    }

    @Test func testDoubleTextRoundTripsOverSeededSample() {
        var generator = SplitMix64(seed: 0x5EED_1847_2700_0001)
        var checked = 0
        for _ in 0 ..< 200_000 {
            let value = Double(bitPattern: UInt64.random(in: 0 ... UInt64.max, using: &generator))
            guard value.isFinite else { continue }
            checked += 1
            #expect(Double(NumberText.text(for: value)) == value)
        }
        #expect(checked > 100_000)
    }

    @Test func testFloatIsNotWidenedToDouble() {
        let value: Float = 1_847.27
        #expect(Double(value).description == "1847.27001953125")
        #expect(NumberText.text(for: value) == "1847.27")
        #expect(NumberText.text(for: NSNumber(value: value)) == "1847.27")
    }

    @Test func testFloatTextRoundTripsOverSeededSample() {
        var generator = SplitMix64(seed: 0x5EED_0000_F10A_7000)
        for _ in 0 ..< 200_000 {
            let value = Float(bitPattern: UInt32.random(in: 0 ... UInt32.max, using: &generator))
            guard value.isFinite else { continue }
            #expect(Float(NumberText.text(for: value)) == value)
        }
    }

    @Test func testExponentialFormsAreNeverTrimmed() {
        var generator = SplitMix64(seed: 0x5EED_E4A0_0000_0011)
        for _ in 0 ..< 200_000 {
            let value = Double(bitPattern: UInt64.random(in: 0 ... UInt64.max, using: &generator))
            guard value.isFinite else { continue }
            let text = NumberText.text(for: value)
            if text.contains("e") {
                #expect(!text.hasSuffix(".0"))
            }
        }
    }

    @Test func testBoundaryValues() {
        #expect(NumberText.text(for: Double.leastNonzeroMagnitude) == "5e-324")
        #expect(NumberText.text(for: Double.greatestFiniteMagnitude) == "1.7976931348623157e+308")
        #expect(NumberText.text(for: -0.0) == "-0")
        #expect(NumberText.text(for: 0.0) == "0")
        #expect(Double(NumberText.text(for: -0.0))?.sign == .minus)
    }

    @Test func testIntegerNumbersAreUnchanged() {
        #expect(NumberText.text(for: NSNumber(value: Int64.max)) == "9223372036854775807")
        #expect(NumberText.text(for: NSNumber(value: Int64.min)) == "-9223372036854775808")
        #expect(NumberText.text(for: NSNumber(value: UInt64.max)) == "18446744073709551615")
    }

    @Test func testNestedJsonUsesShortestRoundTripNumbers() {
        let value: [String: Any] = ["label": "a", "rate": 0.1, "ratio": 1.0 / 3.0, "qty": 3.0]
        #expect(NumberText.json(from: value) == #"{"label":"a","qty":3,"rate":0.1,"ratio":0.3333333333333333}"#)
    }

    @Test func testNestedJsonDiffersFromJSONSerialization() throws {
        let value: [String: Any] = ["rate": 0.1]
        let serialized = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        #expect(String(data: serialized, encoding: .utf8) == #"{"rate":0.10000000000000001}"#)
        #expect(NumberText.json(from: value) == #"{"rate":0.1}"#)
    }

    @Test func testNestedJsonHandlesArraysNullsAndBooleans() {
        let value: [String: Any] = [
            "items": [1_847.27, 1.0, "x", NSNull()],
            "flag": true,
            "count": 5
        ]
        #expect(NumberText.json(from: value) == #"{"count":5,"flag":true,"items":[1847.27,1,"x",null]}"#)
    }

    @Test func testNestedJsonKeysAreSorted() {
        let value: [String: Any] = ["b": 1.5, "a": 2.5, "c": 3.5]
        #expect(NumberText.json(from: value) == #"{"a":2.5,"b":1.5,"c":3.5}"#)
    }

    @Test func testNestedJsonRejectsUnsupportedAndNonFiniteValues() {
        #expect(NumberText.json(from: ["date": Date()]) == nil)
        #expect(NumberText.json(from: ["value": Double.nan]) == nil)
        #expect(NumberText.json(from: ["value": Double.infinity]) == nil)
    }

    @Test func testRawNumberIsWrittenVerbatimAtAnyPrecision() {
        let digits = "12345678901234567890123456789012"
        let raw = NumberText.RawNumber(digits)
        #expect(raw != nil)
        #expect(NumberText.json(from: ["v": raw as Any]) == #"{"v":\#(digits)}"#)
        #expect(NumberText.json(from: ["v": NumberText.RawNumber("0.100") as Any]) == #"{"v":0.100}"#)
    }

    @Test func testRawNumberRejectsAnythingThatIsNotAJsonNumber() {
        #expect(NumberText.RawNumber("NaN") == nil)
        #expect(NumberText.RawNumber("Infinity") == nil)
        #expect(NumberText.RawNumber("-Infinity") == nil)
        #expect(NumberText.RawNumber("") == nil)
        #expect(NumberText.RawNumber("1.2.3") == nil)
    }

    @Test func testJsonNumberLiteralAcceptsWidthsBeyondInt64() {
        #expect(NumberText.isJSONNumberLiteral("12345678901234567890123456789012"))
        #expect(!NumberText.isJSONNumber("12345678901234567890123456789012"))
        #expect(!NumberText.isJSONNumberLiteral("007"))
        #expect(!NumberText.isJSONNumberLiteral("NaN"))
    }

    @Test func testTruncationOnlyMarksTextItActuallyCut() {
        let long = String(repeating: "a", count: 50)
        #expect(JSONTruncation.truncate(#"{"a":1}"#, maxLength: 100) == #"{"a":1}"#)
        #expect(JSONTruncation.truncate(long, maxLength: 10).hasSuffix("..."))
        #expect((JSONTruncation.truncate(long, maxLength: 10) as NSString).length == 13)
    }

    @Test func testTruncationCutsInUtf16UnitsNotCharacters() {
        let emoji = String(repeating: "🎉", count: 50)
        let cut = JSONTruncation.truncate(emoji, maxLength: 10) as NSString
        #expect(cut.length <= 10 + 3)
    }

    /// A half-typed brace is a value the user meant, not text this helper shortened.
    @Test func testIncompleteStructureIgnoresUserTypedText() {
        #expect(!JSONTruncation.isIncompleteStructure("{draft"))
        #expect(!JSONTruncation.isIncompleteStructure("[TODO"))
        #expect(!JSONTruncation.isIncompleteStructure(#"{"a":1}"#))
        #expect(!JSONTruncation.isIncompleteStructure("plain text..."))
        #expect(JSONTruncation.isIncompleteStructure(#"{"a":1, "b":"xx..."#))
    }

    @Test func testIncompleteStructureCatchesEveryCutOfAStructure() {
        let json = #"{"deep":[[1,2],[3,[4]]],"rows":[{"id":1,"ok":true},{"id":-2.5e3,"note":null}],"#
            + #""tags":["a","b\"c","é"],"ctl":"a\u0001b"}"#
        let length = (json as NSString).length
        for maxLength in 1..<length {
            let cut = JSONTruncation.truncate(json, maxLength: maxLength)
            #expect(JSONTruncation.isIncompleteStructure(cut), "\(cut)")
        }
        #expect(!(JSONTruncation.isIncompleteStructure(JSONTruncation.truncate(json, maxLength: length))))
    }

    @Test func testIncompleteStructureCatchesACutRightAfterAnInnerCloser() {
        #expect(JSONTruncation.isIncompleteStructure(#"[{"a":1},{"a":2}..."#))
        #expect(JSONTruncation.isIncompleteStructure("[[1,2],[3,4]..."))
    }

    @Test func testIncompleteStructureIgnoresProseThatOpensWithABracket() {
        #expect(!JSONTruncation.isIncompleteStructure("[DRAFT] Chapter one..."))
        #expect(!JSONTruncation.isIncompleteStructure("[Note: see below..."))
        #expect(!JSONTruncation.isIncompleteStructure("{see notes} and more..."))
        #expect(!JSONTruncation.isIncompleteStructure(#"{"a":1}..."#))
    }

    @Test func testIncompleteStructureReadsBareWordsAsNumbersOrLiterals() {
        #expect(JSONTruncation.isIncompleteStructure("[1,inf,-inf,nan,tr..."))
    }
}
