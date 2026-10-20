import Foundation
@testable import TableProTabularIO
import Testing

struct JSONPrettyPrinterTests {
    @Test func keepsKeyOrderAndIndentsByTwoSpaces() {
        let text = #"{"b":1,"a":{"d":true,"c":null},"e":["x",2]}"#
        #expect(JSONPrettyPrinter.format(text) == """
        {
          "b": 1,
          "a": {
            "d": true,
            "c": null
          },
          "e": [
            "x",
            2
          ]
        }
        """)
    }

    @Test func copiesNumberLexemes() {
        let text = "[1.50,1E+2,-0,123456789012345678901234567890,1e-7,0.1]"
        #expect(JSONPrettyPrinter.format(text) == "[\n  1.50,\n  1E+2,\n  -0,\n  123456789012345678901234567890,\n  1e-7,\n  0.1\n]")
    }

    @Test func copiesEscapesAsWritten() {
        let text = #"{"k\"ey":"a\\b\n\u00e9\ud83d\ude00\/","raw":"é 😀"}"#
        #expect(JSONPrettyPrinter.format(text) == #"""
        {
          "k\"ey": "a\\b\n\u00e9\ud83d\ude00\/",
          "raw": "é 😀"
        }
        """#)
    }

    @Test func keepsEmptyContainersOnOneLine() {
        #expect(JSONPrettyPrinter.format(#"{"a":{},"b":[ ],"c":[{ }]}"#) == """
        {
          "a": {},
          "b": [],
          "c": [
            {}
          ]
        }
        """)
        #expect(JSONPrettyPrinter.format("[]") == "[]")
        #expect(JSONPrettyPrinter.format(" { } ") == "{}")
    }

    @Test func dropsWhitespaceOutsideStringsOnly() {
        #expect(JSONPrettyPrinter.format("  [ \"a  b\" ,\r\n\t\"c\" ]  ") == "[\n  \"a  b\",\n  \"c\"\n]")
    }

    @Test func printsAScalarDocumentAsWritten() {
        #expect(JSONPrettyPrinter.format(" \"x\" ") == "\"x\"")
        #expect(JSONPrettyPrinter.format("42") == "42")
        #expect(JSONPrettyPrinter.format("null") == "null")
    }

    @Test func formattingItsOwnOutputChangesNothing() throws {
        let pretty = try #require(JSONPrettyPrinter.format(#"{"user":{"name":"a","emails":["x@y.z"]},"tags":[1,2,3]}"#))
        #expect(JSONPrettyPrinter.format(pretty) == pretty)
    }

    @Test(arguments: ["", "   ", #"{"a":}"#, "[1,]", "01", #"{"a" 1}"#, #""\q""#, "\"a\tb\"", "[1] x", "{'a':1}", "NaN", "[1,2", #"{"a":1}}"#])
    func returnsNilForInvalidText(_ text: String) {
        #expect(JSONPrettyPrinter.format(text) == nil)
    }

    @Test func returnsNilAboveFiveHundredThousandCharacters() {
        let fits = "\"" + String(repeating: "a", count: 499_998) + "\""
        #expect(JSONPrettyPrinter.format(fits) == fits)
        #expect(JSONPrettyPrinter.format("\"" + String(repeating: "a", count: 499_999) + "\"") == nil)
    }

    @Test func indentsSixHundredLevels() throws {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        let pretty = try #require(JSONPrettyPrinter.format(deep))
        let lines = pretty.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 1_199)
        #expect(lines[599] == String(repeating: " ", count: 1_198) + "[]")
    }

    @Test func returnsNilWhenIndentationOutgrowsTheOutputBudget() {
        let deep = String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000)
        #expect(JSONPrettyPrinter.format(deep) == nil)
    }
}
