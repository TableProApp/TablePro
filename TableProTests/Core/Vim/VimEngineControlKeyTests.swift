//
//  VimEngineControlKeyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class VimEngineControlKeyTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        let lines = (0..<30).map { "line\($0) text" }
        buffer = VimTextBufferMock(text: lines.joined(separator: "\n") + "\n")
        engine = VimEngine(buffer: buffer)
    }

    private func useText(_ text: String) {
        buffer = VimTextBufferMock(text: text)
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    @discardableResult
    private func control(_ letter: Character) -> Bool {
        let code = (letter.asciiValue ?? 0) & 0x1F
        return engine.process(Character(UnicodeScalar(code)), shift: false)
    }

    private var pos: Int { buffer.selectedRange().location }

    private var line: Int { buffer.lineAndColumn(forOffset: pos).line }

    private func caret(atLine line: Int, column: Int = 0) {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: line, column: column), length: 0))
    }

    // MARK: - Normal mode

    @Test
    func controlRRedoesThroughTheEngine() {
        #expect(control("r"))
        #expect(buffer.redoCallCount == 1)
    }

    @Test
    func controlRTakesACount() {
        keys("3")
        control("r")
        #expect(buffer.redoCallCount == 3)
    }

    @Test
    func controlHMovesLeftLikeH() {
        caret(atLine: 0, column: 5)
        let original = buffer.text
        #expect(control("h"))
        #expect(pos == 4)
        #expect(buffer.text == original, "Ctrl+H must move the caret in Normal mode, never delete")
    }

    @Test
    func controlHTakesACount() {
        caret(atLine: 0, column: 5)
        keys("3")
        control("h")
        #expect(pos == 2)
    }

    @Test
    func controlNAndControlPMoveBetweenLines() {
        caret(atLine: 4, column: 2)
        control("n")
        #expect(line == 5)
        control("p")
        control("p")
        #expect(line == 3)
    }

    @Test
    func controlNCompletesAPendingOperatorLikeJ() {
        useText("one\ntwo\nthree\n")
        keys("d")
        control("n")
        #expect(buffer.text == "three\n", "d followed by Ctrl+N deletes two lines, as dj does")
    }

    @Test
    func scrollControlCancelsAPendingOperator() {
        useText("one two three\n")
        keys("d")
        control("d")
        keys("w")
        #expect(buffer.text == "one two three\n", "Ctrl+D is no motion, so it abandons the pending d")
        #expect(engine.pendingOperator == nil)
    }

    @Test
    func scrollControlUsesAndConsumesItsCount() {
        caret(atLine: 0)
        keys("4")
        control("d")
        #expect(line == 4, "A count sets how many lines Ctrl+D moves")
        keys("j")
        #expect(line == 5, "The count must not carry over to the next command")
    }

    @Test
    func unboundControlCharacterDoesNotEditInNormalMode() {
        caret(atLine: 0, column: 3)
        let original = buffer.text
        #expect(control("k"))
        #expect(control("o"))
        #expect(control("t"))
        #expect(buffer.text == original)
        #expect(engine.mode == .normal)
    }

    @Test
    func optionTypedCharactersDoNotEditInNormalMode() {
        caret(atLine: 0, column: 3)
        let original = buffer.text
        #expect(engine.process("\u{02D9}", shift: false))
        #expect(engine.process("\u{00A0}", shift: false))
        #expect(buffer.text == original)
    }

    @Test
    func replaceCharConsumesAControlCharacterWithoutWritingIt() {
        useText("hello\n")
        keys("r")
        control("d")
        keys("x")
        #expect(buffer.text == "ello\n", "r takes Ctrl+D as its argument, so the next x deletes")
    }

    // MARK: - Visual mode

    @Test
    func controlDExtendsTheVisualSelection() {
        caret(atLine: 0)
        keys("v")
        control("d")
        let selection = buffer.selectedRange()
        #expect(selection.location == 0)
        #expect(buffer.lineAndColumn(forOffset: selection.location + selection.length - 1).line == 15,
            "Ctrl+D moves the visual cursor half the visible lines down")
        #expect(engine.mode == .visual(linewise: false))
    }

    @Test
    func controlHMovesTheVisualCursor() {
        caret(atLine: 0)
        keys("vll")
        control("h")
        #expect(buffer.selectedRange() == NSRange(location: 0, length: 2))
    }

    @Test
    func unboundControlCharacterLeavesTheVisualSelection() {
        caret(atLine: 0)
        keys("vl")
        let original = buffer.text
        control("k")
        #expect(buffer.text == original)
        #expect(buffer.selectedRange() == NSRange(location: 0, length: 2))
        #expect(engine.mode == .visual(linewise: false))
    }

    // MARK: - Insert and Replace mode

    @Test
    func controlHInInsertModeIsLeftToTheTextView() {
        useText("a\u{1F600}b\n")
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("i")
        #expect(!control("h"), "Insert mode Ctrl+H is the text view's deleteBackward, as Delete is")
        #expect(buffer.text == "a\u{1F600}b\n")
        #expect(engine.mode == .insert)
    }

    @Test
    func controlHInReplaceModeRestoresLikeBackspace() {
        useText("hello\n")
        _ = engine.process("R", shift: true)
        _ = engine.process("X", shift: true)
        _ = engine.process("Y", shift: true)
        control("h")
        #expect(buffer.text == "Xello\n")
        #expect(pos == 1)
    }

    @Test
    func optionTypedCharacterOverwritesInReplaceMode() {
        useText("hello\n")
        _ = engine.process("R", shift: true)
        _ = engine.process("\u{00E9}", shift: false)
        #expect(buffer.text == "\u{00E9}ello\n")
    }

    // MARK: - Command line

    @Test
    func controlHErasesInTheCommandLine() {
        keys(":ab")
        control("h")
        #expect(engine.mode == .commandLine(buffer: ":a"))
    }

    @Test
    func controlCharacterIsNotAppendedToTheCommandLine() {
        keys(":")
        control("d")
        control("k")
        #expect(engine.mode == .commandLine(buffer: ":"))
    }
}
