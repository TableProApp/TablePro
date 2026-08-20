import XCTest
@testable import TableProNumberFormatting

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

final class NumberTextTests: XCTestCase {
    func testGoldenDoubleStrings() {
        XCTAssertEqual(NumberText.text(for: 1847.27), "1847.27")
        XCTAssertEqual(NumberText.text(for: 0.1), "0.1")
        XCTAssertEqual(NumberText.text(for: 1.0), "1")
        XCTAssertEqual(NumberText.text(for: 100.0), "100")
        XCTAssertEqual(NumberText.text(for: 1.0 / 3.0), "0.3333333333333333")
        XCTAssertEqual(NumberText.text(for: 2.6243074014352636e-25), "2.6243074014352636e-25")
        XCTAssertEqual(NumberText.text(for: -3.9192320754595876e-07), "-3.9192320754595876e-07")
    }

    func testShortestRoundTripBeatsNSNumberStringValue() {
        let value = -3.9192320754595876e-07
        XCTAssertNotEqual(Double(NSNumber(value: value).stringValue), value)
        XCTAssertEqual(Double(NumberText.text(for: value)), value)
    }

    func testDecimalNumbersKeepTheirExactDigits() throws {
        for literal in ["99999999999999999999", "0.12345678901234567890123"] {
            let parsed = try JSONSerialization.jsonObject(with: Data(#"{"v": \#(literal)}"#.utf8))
            let number = try XCTUnwrap((parsed as? [String: Any])?["v"] as? NSNumber)
            XCTAssertTrue(number is NSDecimalNumber, "expected NSDecimalNumber for \(literal)")
            XCTAssertEqual(NumberText.text(for: number), literal)
        }
    }

    func testDecimalNumbersKeepTheirExactDigitsInNestedJson() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"big": 99999999999999999999}"#.utf8))
        let value = try XCTUnwrap(parsed as? [String: Any])
        XCTAssertEqual(NumberText.json(from: value), #"{"big":99999999999999999999}"#)
    }

    func testBooleanNumbersKeepTheNumericFormAtThisLayer() {
        XCTAssertEqual(NumberText.text(for: NSNumber(value: true)), "1")
        XCTAssertEqual(NumberText.text(for: NSNumber(value: false)), "0")
    }

    func testBooleansStayTrueAndFalseInsideJson() {
        XCTAssertEqual(NumberText.json(from: ["flag": true]), #"{"flag":true}"#)
    }

    func testPrettyPrintedJsonUsesTheSameNumbers() {
        let json = NumberText.json(from: ["rate": 0.1], prettyPrinted: true)
        XCTAssertEqual(json?.contains("0.1"), true)
        XCTAssertEqual(json?.contains("0.10000000000000001"), false)
    }

    func testDoubleTextRoundTripsOverSeededSample() {
        var generator = SplitMix64(seed: 0x5EED_1847_2700_0001)
        var checked = 0
        for _ in 0 ..< 200_000 {
            let value = Double(bitPattern: UInt64.random(in: 0 ... UInt64.max, using: &generator))
            guard value.isFinite else { continue }
            checked += 1
            XCTAssertEqual(Double(NumberText.text(for: value)), value)
        }
        XCTAssertGreaterThan(checked, 100_000)
    }

    func testFloatIsNotWidenedToDouble() {
        let value: Float = 1847.27
        XCTAssertEqual(Double(value).description, "1847.27001953125")
        XCTAssertEqual(NumberText.text(for: value), "1847.27")
        XCTAssertEqual(NumberText.text(for: NSNumber(value: value)), "1847.27")
    }

    func testFloatTextRoundTripsOverSeededSample() {
        var generator = SplitMix64(seed: 0x5EED_0000_F10A_7000)
        for _ in 0 ..< 200_000 {
            let value = Float(bitPattern: UInt32.random(in: 0 ... UInt32.max, using: &generator))
            guard value.isFinite else { continue }
            XCTAssertEqual(Float(NumberText.text(for: value)), value)
        }
    }

    func testExponentialFormsAreNeverTrimmed() {
        var generator = SplitMix64(seed: 0x5EED_E4A0_0000_0011)
        for _ in 0 ..< 200_000 {
            let value = Double(bitPattern: UInt64.random(in: 0 ... UInt64.max, using: &generator))
            guard value.isFinite else { continue }
            let text = NumberText.text(for: value)
            if text.contains("e") {
                XCTAssertFalse(text.hasSuffix(".0"))
            }
        }
    }

    func testBoundaryValues() {
        XCTAssertEqual(NumberText.text(for: Double.leastNonzeroMagnitude), "5e-324")
        XCTAssertEqual(NumberText.text(for: Double.greatestFiniteMagnitude), "1.7976931348623157e+308")
        XCTAssertEqual(NumberText.text(for: -0.0), "-0")
        XCTAssertEqual(NumberText.text(for: 0.0), "0")
        XCTAssertEqual(Double(NumberText.text(for: -0.0))?.sign, .minus)
    }

    func testIntegerNumbersAreUnchanged() {
        XCTAssertEqual(NumberText.text(for: NSNumber(value: Int64.max)), "9223372036854775807")
        XCTAssertEqual(NumberText.text(for: NSNumber(value: Int64.min)), "-9223372036854775808")
        XCTAssertEqual(NumberText.text(for: NSNumber(value: UInt64.max)), "18446744073709551615")
    }

    func testNestedJsonUsesShortestRoundTripNumbers() {
        let value: [String: Any] = ["label": "a", "rate": 0.1, "ratio": 1.0 / 3.0, "qty": 3.0]
        XCTAssertEqual(
            NumberText.json(from: value),
            #"{"label":"a","qty":3,"rate":0.1,"ratio":0.3333333333333333}"#
        )
    }

    func testNestedJsonDiffersFromJSONSerialization() throws {
        let value: [String: Any] = ["rate": 0.1]
        let serialized = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        XCTAssertEqual(String(data: serialized, encoding: .utf8), #"{"rate":0.10000000000000001}"#)
        XCTAssertEqual(NumberText.json(from: value), #"{"rate":0.1}"#)
    }

    func testNestedJsonHandlesArraysNullsAndBooleans() {
        let value: [String: Any] = [
            "items": [1847.27, 1.0, "x", NSNull()],
            "flag": true,
            "count": 5
        ]
        XCTAssertEqual(
            NumberText.json(from: value),
            #"{"count":5,"flag":true,"items":[1847.27,1,"x",null]}"#
        )
    }

    func testNestedJsonKeysAreSorted() {
        let value: [String: Any] = ["b": 1.5, "a": 2.5, "c": 3.5]
        XCTAssertEqual(NumberText.json(from: value), #"{"a":2.5,"b":1.5,"c":3.5}"#)
    }

    func testNestedJsonRejectsUnsupportedAndNonFiniteValues() {
        XCTAssertNil(NumberText.json(from: ["date": Date()]))
        XCTAssertNil(NumberText.json(from: ["value": Double.nan]))
        XCTAssertNil(NumberText.json(from: ["value": Double.infinity]))
    }
}
