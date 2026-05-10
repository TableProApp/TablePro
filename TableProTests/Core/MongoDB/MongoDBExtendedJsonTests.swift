//
//  MongoDBExtendedJsonTests.swift
//  TableProTests
//
//  Tests for MongoDBConnection.unwrapExtendedJson(_:) static method.
//

#if canImport(CLibMongoc)

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("MongoDB Extended JSON Unwrapping")
struct MongoDBExtendedJsonTests {

    // MARK: - $oid

    @Test("$oid returns string value")
    func oidReturnsString() {
        let input: [String: Any] = ["$oid": "507f1f77bcf86cd799439011"]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? String == "507f1f77bcf86cd799439011")
    }

    // MARK: - $numberInt

    @Test("$numberInt returns Int32")
    func numberIntReturnsInt32() {
        let input: [String: Any] = ["$numberInt": "42"]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? Int32 == Int32(42))
    }

    // MARK: - $numberLong

    @Test("$numberLong returns Int64")
    func numberLongReturnsInt64() {
        let input: [String: Any] = ["$numberLong": "9999999999"]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? Int64 == Int64(9999999999))
    }

    // MARK: - $numberDouble

    @Test("$numberDouble returns Double")
    func numberDoubleReturnsDouble() {
        let input: [String: Any] = ["$numberDouble": "3.14"]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? Double == 3.14)
    }

    // MARK: - $numberDecimal

    @Test("$numberDecimal returns string representation")
    func numberDecimalReturnsString() {
        let input: [String: Any] = ["$numberDecimal": "99.99"]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? String == "99.99")
    }

    // MARK: - $date

    @Test("$date with $numberLong returns Date")
    func dateWithNumberLongReturnsDate() {
        let input: [String: Any] = ["$date": ["$numberLong": "1609459200000"]]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        if let date = result as? Date {
            let expected = Date(timeIntervalSince1970: 1609459200)
            #expect(abs(date.timeIntervalSince1970 - expected.timeIntervalSince1970) < 1)
        } else {
            Issue.record("Expected Date but got \(type(of: result))")
        }
    }

    @Test("$date with ISO string returns Date")
    func dateWithIsoStringReturnsDate() {
        let input: [String: Any] = ["$date": "2021-01-01T00:00:00.000Z"]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        if let date = result as? Date {
            let expected = Date(timeIntervalSince1970: 1609459200)
            #expect(abs(date.timeIntervalSince1970 - expected.timeIntervalSince1970) < 1)
        } else {
            Issue.record("Expected Date but got \(type(of: result))")
        }
    }

    // MARK: - $binary

    @Test("$binary returns Data containing decoded bytes")
    func binaryReturnsData() {
        let input: [String: Any] = ["$binary": ["base64": "SGVsbG8=", "subType": "00"]]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        if let data = result as? Data {
            #expect(String(data: data, encoding: .utf8) == "Hello")
        } else {
            Issue.record("Expected Data but got \(type(of: result))")
        }
    }

    // MARK: - $timestamp

    @Test("$timestamp returns formatted string")
    func timestampReturnsFormattedString() {
        let input: [String: Any] = ["$timestamp": ["t": 1, "i": 1]]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? String == "Timestamp(1, 1)")
    }

    // MARK: - $minKey / $maxKey

    @Test("$minKey returns MinKey string")
    func minKeyReturnsString() {
        let input: [String: Any] = ["$minKey": 1]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? String == "MinKey")
    }

    @Test("$maxKey returns MaxKey string")
    func maxKeyReturnsString() {
        let input: [String: Any] = ["$maxKey": 1]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? String == "MaxKey")
    }

    // MARK: - $undefined

    @Test("$undefined returns NSNull")
    func undefinedReturnsNSNull() {
        let input: [String: Any] = ["$undefined": true]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result is NSNull)
    }

    // MARK: - $regularExpression

    @Test("$regularExpression returns formatted regex string")
    func regularExpressionReturnsFormattedString() {
        let input: [String: Any] = ["$regularExpression": ["pattern": "^abc", "options": "i"]]
        let result = MongoDBConnection.unwrapExtendedJson(input)
        #expect(result as? String == "/^abc/i")
    }

    // MARK: - Recursive Unwrapping

    @Test("Nested dict recursively unwraps extended JSON values")
    func nestedDictRecursivelyUnwraps() {
        let input: [String: Any] = [
            "user": [
                "name": "John",
                "age": ["$numberInt": "30"]
            ] as [String: Any]
        ]
        let result = MongoDBConnection.unwrapExtendedJson(input)

        guard let dict = result as? [String: Any],
              let user = dict["user"] as? [String: Any] else {
            Issue.record("Expected nested dictionary structure")
            return
        }

        #expect(user["name"] as? String == "John")
        #expect(user["age"] as? Int32 == Int32(30))
    }

    @Test("Array of extended JSON values recursively unwraps")
    func arrayRecursivelyUnwraps() {
        let input: [[String: Any]] = [
            ["$numberInt": "1"],
            ["$numberInt": "2"]
        ]
        let result = MongoDBConnection.unwrapExtendedJson(input)

        guard let array = result as? [Any] else {
            Issue.record("Expected array result")
            return
        }

        #expect(array.count == 2)
        #expect(array[0] as? Int32 == Int32(1))
        #expect(array[1] as? Int32 == Int32(2))
    }

    // MARK: - Pass-Through

    @Test("Plain string passes through unchanged")
    func plainStringPassesThrough() {
        let result = MongoDBConnection.unwrapExtendedJson("hello")
        #expect(result as? String == "hello")
    }

    @Test("Plain integer passes through unchanged")
    func plainIntPassesThrough() {
        let result = MongoDBConnection.unwrapExtendedJson(42)
        #expect(result as? Int == 42)
    }

    // MARK: - Multi-Key Dict (Not Extended JSON)

    @Test("Multi-key dict recursively unwraps values but is not treated as extended JSON")
    func multiKeyDictRecursivelyUnwrapsValues() {
        let input: [String: Any] = [
            "name": "John",
            "age": ["$numberInt": "30"]
        ]
        let result = MongoDBConnection.unwrapExtendedJson(input)

        guard let dict = result as? [String: Any] else {
            Issue.record("Expected dictionary result")
            return
        }

        #expect(dict["name"] as? String == "John")
        #expect(dict["age"] as? Int32 == Int32(30))
    }
}

#endif
