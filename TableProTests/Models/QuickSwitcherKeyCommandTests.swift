//
//  QuickSwitcherKeyCommandTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct QuickSwitcherKeyCommandTests {
    private let scopeCount = QuickSwitcherScope.allCases.count

    private func resolve(
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags
    ) -> QuickSwitcherKeyCommand? {
        QuickSwitcherKeyCommand.resolve(
            characters: characters,
            modifiers: modifiers,
            scopeCount: scopeCount
        )
    }

    // MARK: - Commit Intent

    @Test("Return with no modifiers opens in the current tab")
    func plainReturnOpensInPlace() {
        #expect(QuickSwitcherKeyCommand.commitIntent(for: []) == .open)
    }

    @Test("Option and Command both mean open in a new tab")
    func optionAndCommandOpenInNewTab() {
        #expect(QuickSwitcherKeyCommand.commitIntent(for: .option) == .openInNewWindowTab)
        #expect(QuickSwitcherKeyCommand.commitIntent(for: .command) == .openInNewWindowTab)
        #expect(QuickSwitcherKeyCommand.commitIntent(for: [.command, .option]) == .openInNewWindowTab)
    }

    /// Shift and Control are not commit modifiers, so they must not silently open a new tab.
    @Test("Modifiers that are not commit modifiers open in the current tab")
    func unrelatedModifiersOpenInPlace() {
        #expect(QuickSwitcherKeyCommand.commitIntent(for: .shift) == .open)
        #expect(QuickSwitcherKeyCommand.commitIntent(for: .control) == .open)
    }

    // MARK: - Command-Return

    @Test("Command-Return resolves to a new-tab commit")
    func commandReturnCommitsToNewTab() {
        #expect(resolve("\r", .command) == .commit(.openInNewWindowTab))
    }

    /// The numeric keypad's Enter reports U+0003, not a carriage return.
    @Test("Command-Enter on the numeric keypad resolves to a new-tab commit")
    func commandEnterCommitsToNewTab() {
        #expect(resolve("\u{3}", .command) == .commit(.openInNewWindowTab))
    }

    /// Plain Return reaches the field editor, which owns it. Claiming it here would take the
    /// commit away from the search field and break Return on an empty modifier set.
    @Test("Return without Command is left to the field editor")
    func plainReturnIsNotClaimed() {
        #expect(resolve("\r", []) == nil)
        #expect(resolve("\r", .option) == nil)
    }

    @Test("Command-Shift-Return is not claimed")
    func commandShiftReturnIsNotClaimed() {
        #expect(resolve("\r", [.command, .shift]) == nil)
    }

    // MARK: - Scope Selection

    @Test("Command-1 through Command-5 select a scope by position")
    func commandDigitsSelectScopes() {
        #expect(resolve("1", .command) == .selectScope(index: 0))
        #expect(resolve("5", .command) == .selectScope(index: 4))
    }

    @Test("A digit past the last scope is not claimed")
    func digitPastLastScopeIsNotClaimed() {
        #expect(resolve("\(scopeCount + 1)", .command) == nil)
        #expect(resolve("0", .command) == nil)
    }

    // MARK: - Selection Movement

    @Test("Control-J and Control-N move the selection down")
    func controlJAndNMoveDown() {
        #expect(resolve("j", .control) == .moveSelection(by: 1))
        #expect(resolve("n", .control) == .moveSelection(by: 1))
    }

    @Test("Control-K and Control-P move the selection up")
    func controlKAndPMoveUp() {
        #expect(resolve("k", .control) == .moveSelection(by: -1))
        #expect(resolve("p", .control) == .moveSelection(by: -1))
    }

    /// Typing a bare letter has to reach the search field.
    @Test("An unmodified letter is not claimed")
    func unmodifiedLetterIsNotClaimed() {
        #expect(resolve("j", []) == nil)
        #expect(resolve("k", []) == nil)
    }

    @Test("A Control letter the panel does not bind is not claimed")
    func unboundControlLetterIsNotClaimed() {
        #expect(resolve("x", .control) == nil)
    }
}
