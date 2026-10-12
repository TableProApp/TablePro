//
//  FilterValueTextFieldTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

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

    @Test("Arrow keys move the selection whether or not one is already made")
    func testCommandOutcome_arrowKeysAlwaysMove() {
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.moveDown(_:)), hasSelection: false, submitsOnAccept: false
            ) == .moveSelection(1)
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.moveUp(_:)), hasSelection: true, submitsOnAccept: false
            ) == .moveSelection(-1)
        )
    }

    @Test("Return and Tab reach the field until a suggestion is selected")
    func testCommandOutcome_unselectedListPassesKeysThrough() {
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertNewline(_:)), hasSelection: false, submitsOnAccept: true
            ) == .passThrough
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertNewline(_:)), hasSelection: false, submitsOnAccept: false
            ) == .passThrough
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertTab(_:)), hasSelection: false, submitsOnAccept: true
            ) == .passThrough
        )
    }

    @Test("A selected suggestion takes Return, and submits only where accepting completes the value")
    func testCommandOutcome_selectedSuggestionTakesReturn() {
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertNewline(_:)), hasSelection: true, submitsOnAccept: true
            ) == .accept(submitting: true)
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertNewline(_:)), hasSelection: true, submitsOnAccept: false
            ) == .accept(submitting: false)
        )
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.insertTab(_:)), hasSelection: true, submitsOnAccept: true
            ) == .accept(submitting: false)
        )
    }

    @Test("A command the popup does not own passes through to the field editor")
    func testCommandOutcome_passThrough() {
        #expect(
            FilterValueTextField.suggestionCommandOutcome(
                for: #selector(NSResponder.moveLeft(_:)), hasSelection: true, submitsOnAccept: true
            ) == .passThrough
        )
    }

    @Test("An unselected list is entered from the end the arrow points away from")
    func testSelection_entersFromTheArrowEnd() {
        #expect(FilterValueTextField.selection(movedBy: 1, from: nil, count: 3) == 0)
        #expect(FilterValueTextField.selection(movedBy: -1, from: nil, count: 3) == 2)
    }

    @Test("Movement inside the list clamps at both ends")
    func testSelection_clampsInsideTheList() {
        #expect(FilterValueTextField.selection(movedBy: 1, from: 1, count: 3) == 2)
        #expect(FilterValueTextField.selection(movedBy: 1, from: 2, count: 3) == 2)
        #expect(FilterValueTextField.selection(movedBy: -1, from: 1, count: 3) == 0)
        #expect(FilterValueTextField.selection(movedBy: -1, from: 0, count: 3) == 0)
    }

    @Test("An empty list has nothing to select")
    func testSelection_emptyListSelectsNothing() {
        #expect(FilterValueTextField.selection(movedBy: 1, from: nil, count: 0) == nil)
        #expect(FilterValueTextField.selection(movedBy: -1, from: 0, count: 0) == nil)
    }

    /// #2927: the popup used to select its first row the moment it opened, so `Return` accepted a
    /// suggestion the user never asked for and the filter went unapplied until they pressed
    /// `Escape` first. Driven through the coordinator rather than a sleep, so it measures the key
    /// handling and not the debounce.
    @MainActor
    @Test("Return applies the filter while the list is open and unselected")
    func testReturn_appliesTheFilterWhileNothingIsSelected() throws {
        let harness = try SuggestionHarness(values: ["alpha", "alphabet"])
        defer { harness.close() }
        harness.type("alph")

        #expect(harness.send(#selector(NSResponder.insertNewline(_:))))
        #expect(harness.text == "alph")
        #expect(harness.submitted == "alph")
    }

    @MainActor
    @Test("Arrowing to a suggestion gives the list Return back")
    func testReturn_acceptsTheSuggestionTheUserSelected() throws {
        let harness = try SuggestionHarness(values: ["alpha", "alphabet"])
        defer { harness.close() }
        harness.type("alph")

        #expect(harness.send(#selector(NSResponder.moveDown(_:))))
        #expect(harness.send(#selector(NSResponder.insertNewline(_:))))
        #expect(harness.text == "alpha")
        #expect(harness.submitted == "alpha")
    }

    @MainActor
    @Test("Tab reaches the field until a suggestion is selected")
    func testTab_leavesTheFieldWhileNothingIsSelected() throws {
        let harness = try SuggestionHarness(values: ["alpha", "alphabet"])
        defer { harness.close() }
        harness.type("alph")

        #expect(!harness.send(#selector(NSResponder.insertTab(_:))))
        #expect(harness.text == "alph")
        #expect(harness.submitted == nil)
    }

    @MainActor
    @Test("Typing past the last match closes the list and leaves the keys with the field")
    func testNoMatches_closeTheListAndLeaveTheKeys() throws {
        let harness = try SuggestionHarness(values: ["alpha"])
        defer { harness.close() }
        harness.type("alph")
        harness.type("zzz")

        #expect(!harness.send(#selector(NSResponder.moveDown(_:))))
        #expect(harness.send(#selector(NSResponder.insertNewline(_:))))
        #expect(harness.submitted == "zzz")
    }

    @MainActor
    private final class SuggestionHarness {
        private let control = NSTextField(frame: NSRect(x: 20, y: 50, width: 300, height: 24))
        private let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        private let coordinator: FilterValueTextField.Coordinator
        private let box = Box()

        private final class Box {
            var text = ""
            var submitted: String?
        }

        var text: String { box.text }
        var submitted: String? { box.submitted }

        init(values: [String]) throws {
            let box = self.box
            let field = FilterValueTextField(
                text: Binding(get: { box.text }, set: { box.text = $0 }),
                focusedId: .constant(nil),
                identity: UUID(),
                completionSource: .staticValues(values),
                onSubmit: { box.submitted = box.text }
            )
            coordinator = field.makeCoordinator()
            window.contentView?.addSubview(control)
            coordinator.textField = control
        }

        func close() {
            coordinator.dismissSuggestions()
            window.orderOut(nil)
        }

        func type(_ value: String) {
            control.stringValue = value
            coordinator.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: control)
            )
        }

        func send(_ command: Selector) -> Bool {
            coordinator.control(control, textView: NSTextView(), doCommandBy: command)
        }
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
