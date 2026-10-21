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

    @Test(
        "Text the JSON grammar refuses is not valid JSON",
        arguments: [
            "01", "-01", "[00]", #"{"a": 01}"#, #""\q""#, #""\u12""#, #""\uZZZZ""#,
            "\"a\tb\"", "\"a\nb\"", "[1,]", #"{"a":1,}"#, "\u{FEFF}{}", "", "  ", "{} x",
        ]
    )
    func refusesInvalidJson(_ input: String) {
        #expect(!input.isValidJson)
    }

    @Test(
        "Every JSON value passes, scalars and surrounding whitespace included",
        arguments: [
            #"{"a":[1,2.5e-3,-0,true,false,null]}"#, " [ ] ", "0", "-1.5E+3", "1e400", #""é\n""#,
            "\n{\n  \"a\": \"x\"\n}\n",
        ]
    )
    func acceptsValidJson(_ input: String) {
        #expect(input.isValidJson)
    }

    @Test("A text value with a trailing comma is not taken for a JSON document")
    func looksLikeJsonFollowsTheGrammar() {
        #expect(#"{"a":1}"#.looksLikeJson)
        #expect(!#"{"a":1,}"#.looksLikeJson)
        #expect(!"[1,]".looksLikeJson)
        #expect(!"123".looksLikeJson)
    }

    @Test("Slashes are preserved as written")
    func slashesPreserved() throws {
        let input = "{\"url\":\"https://example.com/path/to/resource\"}"
        let result = try #require(input.prettyPrintedAsJson())

        #expect(result.contains("https://example.com/path/to/resource"))
        #expect(!result.contains("\\/"))
    }
}
