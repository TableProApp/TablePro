//
//  VimEngineReplaceTests.swift
//  TableProTests
//
//  Specification tests for r{char} single-character replace and R overwrite mode.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineReplaceTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "hello world\nsecond line\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private func escape() { _ = engine.process("\u{1B}", shift: false) }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - r: Single Character Replace

    @Test
    func rReplacesSingleCharacter() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("rH")
        #expect(buffer.text == "Hello world\nsecond line\n",
            "r should replace the char under the cursor")
    }

    @Test
    func rStaysInNormalMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("rH")
        #expect(engine.mode == .normal,
            "r is a single-shot command; it must not enter insert mode")
    }

    @Test
    func rDoesNotMoveCursor() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("rX")
        #expect(pos == 5, "r should leave the cursor on the replaced char")
    }

    @Test
    func rWithCountReplacesMultipleChars() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3rX")
        #expect(buffer.text == "XXXlo world\nsecond line\n",
            "3rX should replace the next 3 chars with X")
    }

    @Test
    func rWithCountCursorOnLastReplaced() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3rX")
        #expect(pos == 2, "Cursor should sit on the last replaced char")
    }

    @Test
    func rCountExceedingLineRemainderIsNoOp() {
        // "hello world\n" — from offset 8 only 3 content chars remain ('rld'). 99rX must
        // not replace any chars (vim refuses to cross the newline).
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("99rX")
        #expect(buffer.text == "hello world\nsecond line\n",
            "r with count exceeding line content should be a no-op (must not overwrite newline)")
    }

    @Test
    func rWithNewlineReplacesCharWithNewline() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("r")
        _ = engine.process("\r", shift: false)
        #expect(buffer.text == "hello\nworld\nsecond line\n",
            "r<Enter> should replace the char with a newline")
    }

    @Test
    func rEscapeCancelsReplace() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("r")
        escape()
        #expect(buffer.text == "hello world\nsecond line\n",
            "Escape during r prompt should cancel without modifying buffer")
        // Cursor should remain at offset 0 and mode normal.
        #expect(engine.mode == .normal)
    }

    // MARK: - R: Overwrite Mode

    @Test
    func capitalREntersReplaceMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        #expect(engine.mode == .replace,
            "R should enter the dedicated .replace mode (overwrite, distinct from insert)")
    }

    @Test
    func capitalROverwritesCharactersAsTyped() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        _ = engine.process("X", shift: true)
        _ = engine.process("Y", shift: true)
        #expect(buffer.text == "XYllo world\nsecond line\n",
            "Replace mode should overwrite chars at the cursor as the user types")
    }

    @Test
    func capitalREscapeReturnsToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        escape()
        #expect(engine.mode == .normal)
    }

    // MARK: - Control characters never become text

    private let backspace: Character = "\u{7F}"

    @Test
    func backspaceInReplaceModeRestoresOverwrittenCharacters() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        _ = engine.process("X", shift: true)
        _ = engine.process("Y", shift: true)
        key(backspace)
        #expect(buffer.text == "Xello world\nsecond line\n")
        #expect(pos == 1)
        key(backspace)
        #expect(buffer.text == "hello world\nsecond line\n")
        #expect(pos == 0)
    }

    @Test
    func backspaceInReplaceModeRemovesAppendedCharacters() {
        buffer.setSelectedRange(NSRange(location: 11, length: 0))
        key("R", shift: true)
        keys("!?")
        #expect(buffer.text == "hello world!?\nsecond line\n")
        key(backspace)
        key(backspace)
        #expect(buffer.text == "hello world\nsecond line\n")
        #expect(pos == 11)
    }

    @Test
    func backspaceBeforeReplaceStartOnlyMovesLeft() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        key("R", shift: true)
        key(backspace)
        #expect(buffer.text == "hello world\nsecond line\n")
        #expect(pos == 2)
    }

    @Test
    func replaceModeNeverWritesAControlCharacter() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        key("\u{03}")
        key("\u{1D}")
        #expect(buffer.text == "hello world\nsecond line\n")
    }

    @Test
    func replaceCharCancelsOnBackspace() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("r")
        key(backspace)
        #expect(buffer.text == "hello world\nsecond line\n")
        #expect(engine.mode == .normal)
        keys("rH")
        #expect(buffer.text == "Hello world\nsecond line\n", "The cancelled r must not leave a pending replace")
    }

    @Test
    func visualReplaceCancelsOnBackspace() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlr")
        key(backspace)
        #expect(buffer.text == "hello world\nsecond line\n")
    }
}
