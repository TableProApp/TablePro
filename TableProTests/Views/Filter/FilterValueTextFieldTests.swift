//
//  FilterValueTextFieldTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import AppKit
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

    @Test("Escape dismisses the popup while it is up, then closes the bar")
    func testEscapeOutcome() {
        #expect(FilterValueTextField.escapeOutcome(popupVisible: true, recentlyDismissedPopup: false) == .dismissPopup)
        #expect(FilterValueTextField.escapeOutcome(popupVisible: false, recentlyDismissedPopup: true) == .consume)
        #expect(FilterValueTextField.escapeOutcome(popupVisible: false, recentlyDismissedPopup: false) == .closeBar)
    }

    @Test("Arrow and accept commands map to consuming outcomes")
    func testCommandOutcome_navigationAndAccept() {
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.moveDown(_:)), submitsOnAccept: false
            ) == .moveSelection(1)
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.moveUp(_:)), submitsOnAccept: false
            ) == .moveSelection(-1)
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertNewline(_:)), submitsOnAccept: true
            ) == .accept(submitting: true)
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertTab(_:)), submitsOnAccept: true
            ) == .accept(submitting: false)
        )
    }

    @Test("A command the popup does not own passes through to the field editor")
    func testCommandOutcome_passThrough() {
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.moveLeft(_:)), submitsOnAccept: true
            ) == .passThrough
        )
    }

    @Test("Token completion is offered while typing a partial token")
    func testTokenCompletion_offeredForPartialToken() {
        #expect(FilterValueTextField.shouldOfferTokenCompletion(fieldText: "cre", cursor: 3))
        #expect(FilterValueTextField.shouldOfferTokenCompletion(fieldText: "id = 1 AND cre", cursor: 14))
    }

    @Test("Token completion is suppressed when the cursor follows whitespace")
    func testTokenCompletion_suppressedAfterWhitespace() {
        #expect(!FilterValueTextField.shouldOfferTokenCompletion(fieldText: " ", cursor: 1))
        #expect(!FilterValueTextField.shouldOfferTokenCompletion(fieldText: "id = ", cursor: 5))
        #expect(!FilterValueTextField.shouldOfferTokenCompletion(fieldText: "name AND ", cursor: 9))
    }

    @Test("Token completion is suppressed for an empty field or a leading cursor")
    func testTokenCompletion_suppressedForEmptyOrLeadingCursor() {
        #expect(!FilterValueTextField.shouldOfferTokenCompletion(fieldText: "", cursor: 0))
        #expect(!FilterValueTextField.shouldOfferTokenCompletion(fieldText: "name", cursor: 0))
    }

    @Test("Token completion clamps an out-of-range cursor to the field length")
    func testTokenCompletion_clampsCursor() {
        #expect(FilterValueTextField.shouldOfferTokenCompletion(fieldText: "name", cursor: 99))
        #expect(!FilterValueTextField.shouldOfferTokenCompletion(fieldText: "name ", cursor: 99))
    }

    @Test("A trailing non-BMP character counts as non-whitespace and still offers completion")
    func testTokenCompletion_trailingAstralCharacter() {
        let text = "name😀"
        #expect(FilterValueTextField.shouldOfferTokenCompletion(fieldText: text, cursor: (text as NSString).length))
    }

    @Test("Escape dismisses the popup when one is visible")
    func testEscapeOutcome_dismissesVisiblePopup() {
        #expect(FilterValueTextField.escapeOutcome(popupVisible: true, recentlyDismissedPopup: false) == .dismissPopup)
        #expect(FilterValueTextField.escapeOutcome(popupVisible: true, recentlyDismissedPopup: true) == .dismissPopup)
    }

    @Test("The Escape right after dismissing the popup is consumed, keeping the filter bar open")
    func testEscapeOutcome_consumesGraceEscape() {
        #expect(FilterValueTextField.escapeOutcome(popupVisible: false, recentlyDismissedPopup: true) == .consume)
    }

    @Test("A clean Escape with no popup closes the filter bar")
    func testEscapeOutcome_closesBar() {
        #expect(FilterValueTextField.escapeOutcome(popupVisible: false, recentlyDismissedPopup: false) == .closeBar)
    }
}
