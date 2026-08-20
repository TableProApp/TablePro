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

    // MARK: - Modifiers the keyboard adds on its own

    /// `.deviceIndependentFlagsMask` keeps `.capsLock`, `.numericPad` and `.function` alongside the
    /// four a shortcut is about, so an exact match against it fails for every press made with Caps
    /// Lock engaged. Every command below silently did nothing until the panel stopped comparing
    /// against the whole mask. These are the real flag sets AppKit delivers, not hand-built ones.
    /// The letters are uppercase on purpose. Caps Lock is not only a flag in the mask, it also
    /// changes what `charactersIgnoringModifiers` delivers, so a test that types "j" while claiming
    /// to model Caps Lock proves nothing about the four Control commands.
    @Test("Caps Lock does not disable any command")
    func capsLockDoesNotDisableCommands() {
        #expect(resolve("\r", [.command, .capsLock]) == .commit(.openInNewWindowTab))
        #expect(resolve("3", [.command, .capsLock]) == .selectScope(index: 2))
        #expect(resolve("J", [.control, .capsLock]) == .moveSelection(by: 1))
        #expect(resolve("N", [.control, .capsLock]) == .moveSelection(by: 1))
        #expect(resolve("K", [.control, .capsLock]) == .moveSelection(by: -1))
        #expect(resolve("P", [.control, .capsLock]) == .moveSelection(by: -1))
    }

    /// The keypad's Enter always carries `.numericPad`, so the `\u{3}` arm above was unreachable in
    /// the running app even though its unit test passed.
    @Test("The numeric keypad's own flag does not disable Command-Enter")
    func numericPadFlagDoesNotDisableCommandEnter() {
        #expect(resolve("\u{3}", [.command, .numericPad]) == .commit(.openInNewWindowTab))
    }

    @Test("The function-key flag does not disable a command")
    func functionFlagDoesNotDisableCommands() {
        #expect(resolve("\r", [.command, .function]) == .commit(.openInNewWindowTab))
    }

    /// The normalization must not swallow a modifier that changes the meaning of a press.
    @Test("Normalizing keeps the modifiers a shortcut is about")
    func normalizingKeepsMeaningfulModifiers() {
        #expect(resolve("j", [.command, .control]) == nil)
        #expect(resolve("\r", [.command, .shift]) == nil)
    }
}
