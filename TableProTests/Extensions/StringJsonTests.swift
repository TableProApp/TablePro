//
//  StringJsonTests.swift
//  TableProTests
//
//  Tests for String+JSON pretty-printing extension
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("String+JSON")
struct StringJsonTests {
    @Test("Valid JSON object is pretty-printed with sorted keys")
    func validJsonObject() {
        let input = "{\"name\":\"Alice\",\"age\":30}"
        let result = input.prettyPrintedAsJson()

        #expect(result != nil)
        #expect(result!.contains("\n"))
        let ageRange = result!.range(of: "age")!
        let nameRange = result!.range(of: "name")!
        #expect(ageRange.lowerBound < nameRange.lowerBound)
    }

    @Test("Valid JSON array is pretty-printed")
    func validJsonArray() {
        let input = "[1,2,3]"
        let result = input.prettyPrintedAsJson()

        #expect(result != nil)
        #expect(result!.contains("\n"))
        #expect(result!.contains("["))
        #expect(result!.contains("]"))
        let expected = """
        [
          1,
          2,
          3
        ]
        """
        #expect(result == expected)
    }

    @Test("Invalid JSON returns nil")
    func invalidJson() {
        let input = "not valid json at all"
        let result = input.prettyPrintedAsJson()

        #expect(result == nil)
    }

    @Test("Empty string returns nil")
    func emptyString() {
        let input = ""
        let result = input.prettyPrintedAsJson()

        #expect(result == nil)
    }

    @Test("Nested objects are correctly indented")
    func nestedObjects() {
        let input = "{\"user\":{\"address\":{\"city\":\"Hanoi\"}}}"
        let result = input.prettyPrintedAsJson()

        #expect(result != nil)
        let expected = """
        {
          "user" : {
            "address" : {
              "city" : "Hanoi"
            }
          }
        }
        """
        #expect(result == expected)
    }

    @Test("URLs are not escaped due to withoutEscapingSlashes")
    func urlsNotEscaped() {
        let input = "{\"url\":\"https://example.com/path/to/resource\"}"
        let result = input.prettyPrintedAsJson()

        #expect(result != nil)
        #expect(result!.contains("https://example.com/path/to/resource"))
        #expect(!result!.contains("\\/"))
    }
}
