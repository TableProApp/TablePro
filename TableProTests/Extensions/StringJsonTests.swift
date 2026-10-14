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

struct StringJsonTests {
    @Test("Valid JSON object is pretty-printed preserving key order")
    func validJsonObject() throws {
        let input = "{\"name\":\"Alice\",\"age\":30}"
        let result = try #require(input.prettyPrintedAsJson())

        #expect(result.contains("\n"))
        let nameRange = try #require(result.range(of: "name"))
        let ageRange = try #require(result.range(of: "age"))
        #expect(nameRange.lowerBound < ageRange.lowerBound)
    }

    @Test("Valid JSON array is pretty-printed")
    func validJsonArray() throws {
        let result = try #require("[1,2,3]".prettyPrintedAsJson())
        let expected = """
        [
          1,
          2,
          3
        ]
        """
        #expect(result == expected)
    }

    @Test("Invalid JSON and an empty string return nil", arguments: ["not valid json at all", ""])
    func notJson(_ input: String) {
        #expect(input.prettyPrintedAsJson() == nil)
    }

    @Test("Nested objects are correctly indented")
    func nestedObjects() throws {
        let input = "{\"user\":{\"address\":{\"city\":\"Hanoi\"}}}"
        let result = try #require(input.prettyPrintedAsJson())

        let expected = """
        {
          "user": {
            "address": {
              "city": "Hanoi"
            }
          }
        }
        """
        #expect(result == expected)
    }

    @Test("Slashes are preserved as written")
    func slashesPreserved() throws {
        let input = "{\"url\":\"https://example.com/path/to/resource\"}"
        let result = try #require(input.prettyPrintedAsJson())

        #expect(result.contains("https://example.com/path/to/resource"))
        #expect(!result.contains("\\/"))
    }
}
