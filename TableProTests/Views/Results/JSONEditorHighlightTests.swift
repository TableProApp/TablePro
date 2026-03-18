//
//  JSONEditorHighlightTests.swift
//  TablePro

import Foundation
import Testing

@testable import TablePro

@Suite("JSON Editor Highlighting")
struct JSONEditorHighlightTests {
    // MARK: - String Pattern

    @Test("String pattern matches simple quoted string")
    func stringPatternMatchesSimpleString() {
        let matches = findMatches(JSONHighlightPatterns.string, in: "\"hello\"")
        #expect(matches == ["\"hello\""])
    }

    @Test("String pattern matches escaped quote inside string")
    func stringPatternMatchesEscapedQuote() {
        let matches = findMatches(JSONHighlightPatterns.string, in: "\"escaped \\\"quote\\\"\"")
        #expect(matches == ["\"escaped \\\"quote\\\"\""])
    }

    @Test("String pattern does not match unquoted text")
    func stringPatternIgnoresUnquotedText() {
        let matches = findMatches(JSONHighlightPatterns.string, in: "hello world")
        #expect(matches.isEmpty)
    }

    @Test("String pattern matches multiple strings")
    func stringPatternMatchesMultiple() {
        let matches = findMatches(JSONHighlightPatterns.string, in: "\"a\", \"b\"")
        #expect(matches == ["\"a\"", "\"b\""])
    }

    // MARK: - Key Pattern

    @Test("Key pattern matches key followed by colon")
    func keyPatternMatchesKeyColon() {
        let regex = JSONHighlightPatterns.key
        let input = "\"name\": \"value\""
        let nsInput = input as NSString
        let results = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        #expect(results.count == 1)
        let captureRange = results[0].range(at: 1)
        #expect(nsInput.substring(with: captureRange) == "\"name\"")
    }

    @Test("Key pattern matches key with space before colon")
    func keyPatternMatchesKeySpaceColon() {
        let regex = JSONHighlightPatterns.key
        let input = "\"key\" : 42"
        let nsInput = input as NSString
        let results = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        #expect(results.count == 1)
        let captureRange = results[0].range(at: 1)
        #expect(nsInput.substring(with: captureRange) == "\"key\"")
    }

    // MARK: - Number Pattern

    @Test("Number pattern matches integer in JSON context")
    func numberPatternMatchesInteger() {
        let matches = findMatches(JSONHighlightPatterns.number, in: " 123 ")
        #expect(matches == ["123"])
    }

    @Test("Number pattern matches negative decimal")
    func numberPatternMatchesNegativeDecimal() {
        let matches = findMatches(JSONHighlightPatterns.number, in: ":-3.14}")
        #expect(matches == ["-3.14"])
    }

    @Test("Number pattern matches scientific notation")
    func numberPatternMatchesScientific() {
        let matches = findMatches(JSONHighlightPatterns.number, in: " 1e10 ")
        #expect(matches == ["1e10"])
    }

    @Test("Number pattern matches negative exponent")
    func numberPatternMatchesNegativeExponent() {
        let matches = findMatches(JSONHighlightPatterns.number, in: "[2.5E-3]")
        #expect(matches == ["2.5E-3"])
    }

    // MARK: - Boolean/Null Pattern

    @Test("BooleanNull pattern matches true")
    func booleanNullMatchesTrue() {
        let matches = findMatches(JSONHighlightPatterns.booleanNull, in: "true")
        #expect(matches == ["true"])
    }

    @Test("BooleanNull pattern matches false")
    func booleanNullMatchesFalse() {
        let matches = findMatches(JSONHighlightPatterns.booleanNull, in: "false")
        #expect(matches == ["false"])
    }

    @Test("BooleanNull pattern matches null")
    func booleanNullMatchesNull() {
        let matches = findMatches(JSONHighlightPatterns.booleanNull, in: "null")
        #expect(matches == ["null"])
    }

    @Test("BooleanNull pattern does not match partial words")
    func booleanNullIgnoresPartialWords() {
        let matches = findMatches(JSONHighlightPatterns.booleanNull, in: "trueish falsehood nullable")
        #expect(matches.isEmpty)
    }

    // MARK: - Helpers

    private func findMatches(_ regex: NSRegularExpression, in input: String) -> [String] {
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        return regex.matches(in: input, range: range).map { nsInput.substring(with: $0.range) }
    }
}
