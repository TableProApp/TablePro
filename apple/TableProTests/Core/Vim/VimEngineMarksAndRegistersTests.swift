//
//  VimEngineMarksAndRegistersTests.swift
//  TableProTests
//
//  Specification tests for marks (m / ' / `) and named/numbered registers ("{a-z}, "0-9).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineMarksAndRegistersTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - Marks: Set and Jump

    @Test
    func setMarkAndJumpBackToExactPosition() {
        // mma sets mark 'a' at cursor. Move away. `a jumps back to exact location.
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("`a")
        #expect(pos == 7, "`a should restore the exact cursor offset where mark 'a' was set")
    }

    @Test
    func jumpToMarkLineWithSingleQuote() {
        // 'a jumps to the FIRST non-blank of the marked line (not exact offset).
        buffer = VimTextBufferMock(text: "  one\n  two\n  three\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 4, length: 0)) // line 0 col 4 ('n' in 'one')
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("'a")
        #expect(pos == 2, "'a should jump to first non-blank of the marked line (offset 2)")
    }

    @Test
    func multipleMarks() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("mb")
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("mc")

        keys("`a")
        #expect(pos == 5)
        keys("`b")
        #expect(pos == 15)
        keys("`c")
        #expect(pos == 25)
    }

    @Test
    func overwritingMark() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(pos == 20, "Overwriting a mark should update its position")
    }

    @Test
    func jumpToUnsetMarkIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("`z")
        #expect(pos == 5, "Jumping to an unset mark should not move the cursor")
    }

    @Test
    func marksSurviveEdits() {
        // Set mark, edit elsewhere, mark should still resolve.
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // delete first char — mark should adjust offset accordingly
        keys("`a")
        #expect(pos == 24, "Mark should adjust to compensate for earlier edits")
    }

    // MARK: - Special Mark: '' (Last Jump)

    @Test
    func doubleQuoteJumpsToPreviousPosition() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        // Jump to G (record previous position).
        _ = engine.process("G", shift: true)
        let landedAt = pos
        keys("``")
        #expect(pos == 5, "`` should jump back to the position before the last jump")
        #expect(landedAt != pos)
    }

    // MARK: - Named Registers: Yank

    @Test
    func yankToNamedRegisterAndPaste() {
        // "ayy yanks line into register 'a'. Move, then "ap pastes from 'a'.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"ayy")
        keys("j")
        keys("\"ap")
        #expect(buffer.text == "hello world\nsecond line\nhello world\nthird line\n",
            "Named register 'a' should preserve the yank across other yanks/deletes")
    }

    @Test
    func namedRegisterIndependentFromUnnamed() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"ayy") // 'a' has line 0
        keys("j")
        keys("yy")    // unnamed register has line 1
        // "ap should still paste line 0; p should paste line 1.
        keys("k")
        keys("\"ap")
        #expect(buffer.text == "hello world\nhello world\nsecond line\nthird line\n",
            "Named register 'a' should be unaffected by intervening unnamed yanks")
    }

    @Test
    func deleteToNamedRegister() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"add") // delete line 0 into 'a'
        #expect(buffer.text == "second line\nthird line\n")
        keys("\"ap")
        #expect(buffer.text == "second line\nhello world\nthird line\n",
            "Deleted text should be retrievable from the named register")
    }

    // MARK: - Numbered Registers: Yank Cycle

    @Test
    func yankPopulatesRegisterZero() {
        // y populates register "0 (the yank register).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        // Delete a different line — unnamed register changes but "0 keeps the yank.
        keys("jdd")
        #expect(buffer.text == "hello world\nthird line\n")
        keys("\"0p") // paste from yank register, not from latest delete
        #expect(buffer.text == "hello world\nthird line\nhello world\n",
            "\"0 should preserve the last YANKED text, not the last deleted text")
    }

    @Test
    func deletePopulatesRegisterOne() {
        // d populates register "1; the next d pushes the previous "1 into "2.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd") // line 0 → "1
        keys("dd") // line 1 → "1, old "1 → "2
        #expect(buffer.text == "third line\n")
        keys("\"2p")
        #expect(buffer.text == "third line\nhello world\n",
            "\"2 should hold the previously deleted line after another deletion")
    }

    @Test
    func registersDoNotApplyToMotions() {
        // "a then a motion (no operator) should not crash and should consume the "a sequence.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("\"a")
        keys("l")
        #expect(pos == 6, "Motion after register selection should still execute as a motion")
    }

    // MARK: - Uppercase Named Register (Append)

    @Test
    func uppercaseRegisterAppends() {
        // "Ayy appends to register 'a' (rather than overwriting).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"ayy") // 'a' = "hello world\n"
        keys("j")
        keys("\"A")
        keys("yy") // append "second line\n" to 'a'
        // Now 'a' should contain both lines.
        keys("\"ap")
        #expect(buffer.text.contains("hello world\nsecond line\nhello world\nsecond line\n") == true,
            "Uppercase register should append to lowercase counterpart")
    }

    // MARK: - Marks follow edits made outside the engine

    // Insert mode leaves typing to the text view, which puts the text at the caret.
    private func typeInTextView(_ text: String) {
        buffer.replaceCharacters(in: buffer.selectedRange(), with: text)
    }

    @Test("A line typed above a mark moves the mark down with its line")
    func lineTypedAboveMovesTheMark() {
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("magg")
        key("O", shift: true)
        typeInTextView("new")
        key("\u{1B}")
        keys("`a")
        #expect(pos == 29)
    }

    @Test("Text typed before a mark on its line keeps the mark's column")
    func textTypedOnTheMarkedLineKeepsTheColumn() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("ma0i")
        typeInTextView("XX")
        key("\u{1B}")
        keys("`a")
        #expect(pos == 6)
    }

    @Test("A line pasted above a mark moves the mark down")
    func linePastedAboveMovesTheMark() {
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("maggyy")
        key("P", shift: true)
        keys("`a")
        #expect(pos == 37)
    }

    @Test("A line brought back above a mark, as undo does, moves the mark down")
    func lineRestoredAboveMovesTheMark() {
        keys("dd")
        buffer.setSelectedRange(NSRange(location: 13, length: 0))
        keys("ma")
        buffer.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello world\n")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(pos == 25)
    }

    @Test("Deleting the marked line removes the mark")
    func deletingTheMarkedLineRemovesTheMark() {
        buffer.setSelectedRange(NSRange(location: 13, length: 0))
        keys("madd")
        #expect(engine.marks["a"] == nil)
    }

    @Test("Shifting the marked line keeps the mark on its line and column")
    func shiftKeepsTheMark() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("ma>>`a")
        #expect(buffer.text == "    hello world\nsecond line\nthird line\n")
        #expect(pos == 6)
    }

    @Test("Undoing the delete of a marked line brings the mark back")
    func undoingTheDeleteRestoresTheMark() {
        buffer.setSelectedRange(NSRange(location: 13, length: 0))
        keys("madd")
        buffer.replayUndo(in: NSRange(location: 12, length: 0), with: "second line\n")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(pos == 13)
    }

    @Test("Undoing the delete brings the mark back over one set since, as Vim does")
    func undoingTheDeleteRestoresTheMarkOverANewerOne() {
        buffer.setSelectedRange(NSRange(location: 13, length: 0))
        keys("maddggma")
        buffer.replayUndo(in: NSRange(location: 12, length: 0), with: "second line\n")
        keys("`a")
        #expect(pos == 13)
    }

    @Test("Undo that replaces the pasted lines brings back the marks they took")
    func undoingAReplacementRestoresTheMark() {
        buffer = VimTextBufferMock(text: "foo\nbar\ntail\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        engine.register = VimRegister(text: "new\n", isLinewise: true)
        key("V", shift: true)
        keys("jp")
        #expect(engine.marks["a"] == nil)
        buffer.replayUndo(in: NSRange(location: 0, length: 4), with: "foo\nbar\n")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(pos == 5)
    }

    @Test("An edit before the last insert point on its line keeps the point past the last character")
    func lastInsertPointStaysAtTheLineEnd() {
        buffer = VimTextBufferMock(text: "abc\ntail\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        key("A", shift: true)
        typeInTextView("X")
        key("\u{1B}")
        keys("0rYgi")
        typeInTextView("Z")
        key("\u{1B}")
        #expect(buffer.text == "YbcXZ\ntail\n")
    }

    @Test("Undoing a join puts the mark back on its line")
    func undoingAJoinRestoresTheMark() {
        buffer = VimTextBufferMock(text: "hello world\n    second\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        buffer.setSelectedRange(NSRange(location: 16, length: 0))
        keys("magg")
        key("J", shift: true)
        buffer.replayUndo(in: NSRange(location: 11, length: 1), with: "\n    ")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(buffer.text == "hello world\n    second\n")
        #expect(pos == 16)
    }

    @Test("Undoing an edit after a join, then the join, puts the mark back")
    func undoingNestedEditsRestoresTheMark() {
        buffer = VimTextBufferMock(text: "aaa\nbbb\nccc\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("magg")
        key("J", shift: true)
        keys("05x")
        buffer.replayUndo(in: NSRange(location: 0, length: 0), with: "aaa b")
        buffer.replayUndo(in: NSRange(location: 3, length: 1), with: "\n")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(buffer.text == "aaa\nbbb\nccc\n")
        #expect(pos == 6)
    }

    @Test("Undoing a Visual delete lets gv reselect the restored lines")
    func undoingAVisualDeleteRestoresTheLastSelection() {
        buffer = VimTextBufferMock(text: "aaa\nbbb\nccc\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        keys("j")
        key("V", shift: true)
        keys("d")
        buffer.replayUndo(in: NSRange(location: 4, length: 0), with: "bbb\n")
        keys("gv")
        #expect(buffer.selectedRange() == NSRange(location: 4, length: 4))
    }

    @Test("Undoing a run of backspaces as one edit puts the mark back")
    func undoingCoalescedBackspacesRestoresTheMark() {
        buffer = VimTextBufferMock(text: "aaa\nbbb\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("ma")
        buffer.replaceCharacters(in: NSRange(location: 3, length: 1), with: "")
        buffer.replaceCharacters(in: NSRange(location: 2, length: 1), with: "")
        buffer.replayUndo(in: NSRange(location: 2, length: 0), with: "a\n")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(buffer.text == "aaa\nbbb\n")
        #expect(pos == 6)
    }

    @Test("Two undos in a row restore the marks from before the first edit, not from the first undo")
    func consecutiveUndosRestoreTheOriginalMark() {
        buffer = VimTextBufferMock(text: "aaa\nbbb\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("magg")
        keys("gJ")
        buffer.replaceCharacters(in: NSRange(location: 3, length: 0), with: "\n")
        buffer.replayUndo(in: NSRange(location: 3, length: 1), with: "")
        buffer.replayUndo(in: NSRange(location: 3, length: 0), with: "\n")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(buffer.text == "aaa\nbbb\n")
        #expect(pos == 6)
    }

    @Test("A long insert after a delete does not lose the record its undo needs")
    func longInsertKeepsTheRecordForUndo() {
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("magg")
        keys("c")
        key("G", shift: true)
        for _ in 0..<150 { typeInTextView("x") }
        key("\u{1B}")
        for offset in stride(from: 149, through: 0, by: -1) {
            buffer.replayUndo(in: NSRange(location: offset, length: 1), with: "")
        }
        buffer.replayUndo(in: NSRange(location: 0, length: 0), with: "hello world\nsecond line\nthird line")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        #expect(buffer.text == "hello world\nsecond line\nthird line\n")
        #expect(pos == 25)
    }

    @Test("A mark keeps its column through a line that shrinks and grows back")
    func markColumnSurvivesAShorterLine() {
        buffer = VimTextBufferMock(text: "abcdef\ntail\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        keys("$ma0xxxi")
        // One key at a time, so each key puts back what an `x` took without being its undo.
        for character in ["a", "b", "c"] { typeInTextView(character) }
        key("\u{1B}")
        keys("`a")
        #expect(buffer.text == "abcdef\ntail\n")
        #expect(pos == 5)
    }

    @Test("A join carries the mark with its text")
    func joinCarriesTheMark() {
        buffer = VimTextBufferMock(text: "hello world\n    second\n")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
        buffer.setSelectedRange(NSRange(location: 16, length: 0))
        keys("magg")
        key("J", shift: true)
        keys("`a")
        #expect(buffer.text == "hello world second\n")
        #expect(pos == 12)
    }

    @Test("The last jump position moves with a line typed above it")
    func lastJumpOriginMovesWithEdits() {
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        key("G", shift: true)
        keys("gg")
        key("O", shift: true)
        key("\u{1B}")
        keys("``")
        #expect(pos == 26)
    }
}
