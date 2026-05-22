//
//  FilterValueTextFieldTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Filter Value Text Field Suggestions")
struct FilterValueTextFieldTests {
    @Test("Prefix match is case-insensitive and preserves original case")
    func testSuggestions_prefixMatchCaseInsensitive() {
        let result = FilterValueTextField.suggestions(
            for: "na",
            in: ["id", "Name", "email"]
        )
        #expect(result == ["Name"])
    }

    @Test("No match returns empty")
    func testSuggestions_noMatchReturnsEmpty() {
        let result = FilterValueTextField.suggestions(
            for: "xyz",
            in: ["id", "Name", "email"]
        )
        #expect(result.isEmpty)
    }

    @Test("Single exact match is suppressed")
    func testSuggestions_singleExactMatchSuppressed() {
        let result = FilterValueTextField.suggestions(
            for: "name",
            in: ["name"]
        )
        #expect(result.isEmpty)
    }

    @Test("Multiple matches for common prefix preserve order")
    func testSuggestions_multipleMatchesForCommonPrefix() {
        let result = FilterValueTextField.suggestions(
            for: "created",
            in: ["created_at", "created_by", "name"]
        )
        #expect(result == ["created_at", "created_by"])
    }

    @Test("Empty input returns empty")
    func testSuggestions_emptyInputReturnsEmpty() {
        let result = FilterValueTextField.suggestions(
            for: "",
            in: ["id", "Name", "email"]
        )
        #expect(result.isEmpty)
    }

    @Test("Uppercase input case-insensitive exact match suppressed")
    func testSuggestions_uppercaseInputCaseInsensitive() {
        let result = FilterValueTextField.suggestions(
            for: "ID",
            in: ["id"]
        )
        #expect(result.isEmpty)
    }

    @Test("Partial prefix that does not equal full match still surfaces")
    func testSuggestions_partialPrefixDoesNotSuppress() {
        let result = FilterValueTextField.suggestions(
            for: "nam",
            in: ["name"]
        )
        #expect(result == ["name"])
    }

    @Test("Splice replaces only the token range and preserves surrounding text")
    func testSplice_replacesOnlyTokenRange() {
        let result = FilterValueTextField.splice(
            into: "id = 1 AND cre",
            range: NSRange(location: 11, length: 3),
            insertText: "created_at"
        )
        #expect(result?.text == "id = 1 AND created_at")
    }

    @Test("Splice places the caret after the inserted text")
    func testSplice_caretAfterInsertedText() {
        let result = FilterValueTextField.splice(
            into: "id = 1 AND cre",
            range: NSRange(location: 11, length: 3),
            insertText: "created_at"
        )
        #expect(result?.caret == 21)
    }

    @Test("Splice into the middle of an expression keeps the trailing text")
    func testSplice_keepsTrailingText() {
        let result = FilterValueTextField.splice(
            into: "sta AND id = 1",
            range: NSRange(location: 0, length: 3),
            insertText: "status"
        )
        #expect(result?.text == "status AND id = 1")
        #expect(result?.caret == 6)
    }

    @Test("Splice rejects an out-of-bounds range")
    func testSplice_outOfBoundsReturnsNil() {
        let result = FilterValueTextField.splice(
            into: "abc",
            range: NSRange(location: 5, length: 2),
            insertText: "x"
        )
        #expect(result == nil)
    }
}
