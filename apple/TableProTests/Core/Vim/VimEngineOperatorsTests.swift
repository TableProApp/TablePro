//
//  VimEngineOperatorsTests.swift
//  TableProTests
//
//  Specification tests for the delete (d), change (c), and yank (y) operators,
//  including doublings (dd/cc/yy), shortcuts (D/C/Y/x/X), and operator+motion combos.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineOperatorsTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
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

    // MARK: - x: Delete Character Under Cursor

    @Test
    func xDeletesCharUnderCursor() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x")
        #expect(buffer.text == "ello world\nsecond line\nthird line\n")
    }

    @Test
    func xWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3x")
        #expect(buffer.text == "lo world\nsecond line\nthird line\n")
    }

    @Test
    func xDoesNotCrossNewline() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("5x")
        #expect(buffer.text == "hello worl\nsecond line\nthird line\n",
            "x with count should clamp at the line-terminating newline")
    }

    @Test
    func xOnEmptyLineIsNoOp() {
        buffer = VimTextBufferMock(text: "a\n\nb\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 2, length: 0))
        keys("x")
        #expect(buffer.text == "a\n\nb\n", "x on empty line should leave buffer unchanged")
    }

    @Test
    func xOnLastCharOfLineMovesCursorBack() {
        // After deleting last content char, cursor should sit on the new last content char.
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("x")
        #expect(pos == 9, "After x deletes last content char, cursor moves left")
    }

    // MARK: - X: Delete Character Before Cursor

    @Test
    func capitalXDeletesCharBeforeCursor() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("X", shift: true)
        #expect(buffer.text == "hell world\nsecond line\nthird line\n",
            "X should delete the char to the left of the cursor")
    }

    @Test
    func capitalXWithCount() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("3")
        key("X", shift: true)
        #expect(buffer.text == "he world\nsecond line\nthird line\n")
    }

    @Test
    func capitalXAtLineStartIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        key("X", shift: true)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "X must not cross line boundary backward")
    }

    @Test
    func capitalXAtBufferStartIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("X", shift: true)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n")
    }

    // MARK: - dd: Delete Line

    @Test
    func dDDeletesCurrentLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("dd")
        #expect(buffer.text == "second line\nthird line\n")
    }

    @Test
    func dDWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2dd")
        #expect(buffer.text == "third line\n")
    }

    @Test
    func dDOnLastLineLeavesPreviousLineCursorOnIt() {
        // After deleting last line, cursor should sit on the new last line.
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        keys("dd")
        #expect(buffer.text == "hello world\nsecond line\n")
    }

    @Test
    func dDOnSoleLineEmptiesBuffer() {
        buffer = VimTextBufferMock(text: "only\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd")
        #expect(buffer.text == "")
    }

    @Test
    func dDCountClampsAtBufferEnd() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("99dd")
        #expect(buffer.text == "hello world\n", "dd with large count clamps to remaining lines")
    }

    // MARK: - d + Motion

    @Test
    func dWDeletesToNextWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw")
        #expect(buffer.text == "world\nsecond line\nthird line\n")
    }

    @Test
    func dEDeletesToWordEndInclusive() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("de")
        #expect(buffer.text == " world\nsecond line\nthird line\n",
            "de should delete inclusive of the word-end character")
    }

    @Test
    func dBDeletesBackwardWord() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("db")
        #expect(buffer.text == "world\nsecond line\nthird line\n")
    }

    @Test
    func dDollarDeletesToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("d$")
        #expect(buffer.text == "hello\nsecond line\nthird line\n")
    }

    @Test
    func dZeroDeletesToLineStart() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("d0")
        #expect(buffer.text == " world\nsecond line\nthird line\n")
    }

    @Test
    func dCaretDeletesToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("d^")
        #expect(buffer.text == "   lo\n")
    }

    @Test
    func dGoesGoesAllToEndOfBuffer() {
        // dG from line 0 should delete all lines (linewise).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d")
        key("G", shift: true)
        #expect(buffer.text == "", "dG should delete from current line to end-of-buffer")
    }

    @Test
    func dGGFromMidBufferDeletesToTop() {
        buffer.setSelectedRange(NSRange(location: 14, length: 0))
        keys("dgg")
        #expect(buffer.text == "third line\n",
            "dgg should delete from current line to first line (linewise)")
    }

    @Test
    func dJDeletesTwoLines() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dj")
        #expect(buffer.text == "third line\n",
            "dj should delete current line and the line below (linewise)")
    }

    @Test
    func dKDeletesTwoLines() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("dk")
        #expect(buffer.text == "third line\n",
            "dk should delete current line and the line above (linewise)")
    }

    @Test
    func dCountWordsDeletesMultipleWords() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d3w")
        #expect(buffer.text == "line\nthird line\n",
            "d3w from offset 0 should delete 'hello world\\nsecond '")
    }

    // MARK: - D: Delete to End of Line

    @Test
    func capitalDDeletesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("D", shift: true)
        #expect(buffer.text == "hello\nsecond line\nthird line\n",
            "D is shorthand for d$ and deletes through end-of-line content")
    }

    @Test
    func capitalDOnEmptyLineIsNoOp() {
        buffer = VimTextBufferMock(text: "\nfoo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("D", shift: true)
        #expect(buffer.text == "\nfoo\n", "D on an empty line should not delete the newline")
    }

    // MARK: - yy: Yank Line

    @Test
    func yYDoesNotModifyBuffer() {
        let original = buffer.text
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        #expect(buffer.text == original)
    }

    @Test
    func yYThenPasteRestoresLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        #expect(buffer.text == "hello world\nhello world\nsecond line\nthird line\n")
    }

    @Test
    func yYWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2yyp")
        #expect(buffer.text == "hello world\nhello world\nsecond line\nsecond line\nthird line\n",
            "2yy should yank two lines, p pastes them after current line")
    }

    @Test
    func yYCursorStaysAtLineStart() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("yy")
        // Yank doesn't move cursor across lines; column may be preserved or cursor returned to motion start.
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 0)
    }

    // MARK: - y + Motion

    @Test
    func yWYanksWordIntoRegister() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw")
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "yw must not modify the buffer")
    }

    @Test
    func yWThenPasteInsertsWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ywp")
        #expect(buffer.text == "hhello ello world\nsecond line\nthird line\n",
            "After yw, p pastes 'hello ' after the cursor at offset 0")
    }

    @Test
    func yDollarYanksToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("y$p")
        #expect(buffer.text == "hello  worldworld\nsecond line\nthird line\n",
            "y$ from offset 5 yanks ' world', p pastes it after cursor")
    }

    // MARK: - Y: Yank Line (synonym of yy)

    @Test
    func capitalYYanksLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("Y", shift: true)
        keys("p")
        #expect(buffer.text == "hello world\nhello world\nsecond line\nthird line\n",
            "Y is a synonym for yy and yanks the whole line linewise")
    }

    // MARK: - cc: Change Line

    @Test
    func cCDeletesLineContentEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("cc")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "\nsecond line\nthird line\n")
        #expect(pos == 0)
    }

    @Test
    func cCWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2cc")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "\nthird line\n",
            "2cc should clear two lines' content and leave one newline")
    }

    // MARK: - c + Motion

    @Test
    func cWChangesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("cw")
        #expect(engine.mode == .insert)
        #expect(buffer.text == " world\nsecond line\nthird line\n")
    }

    @Test
    func cDollarChangesToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("c$")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "hello\nsecond line\nthird line\n")
    }

    @Test
    func cEChangesToWordEndInclusive() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ce")
        #expect(buffer.text == " world\nsecond line\nthird line\n",
            "ce should delete through the word-end character")
    }

    // MARK: - C: Change to End of Line

    @Test
    func capitalCChangesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("C", shift: true)
        #expect(engine.mode == .insert)
        #expect(buffer.text == "hello\nsecond line\nthird line\n",
            "C is shorthand for c$")
    }

    // MARK: - Pending Operator Cancellation

    @Test
    func pendingDCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d")
        escape()
        keys("l")
        #expect(pos == 1)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "Escape should cancel the pending operator without modifying the buffer")
    }

    @Test
    func pendingCCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("c")
        escape()
        keys("l")
        #expect(pos == 1)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n")
    }

    @Test
    func pendingYCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("y")
        escape()
        keys("p")
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "Cancelled yank should leave the register untouched")
    }

    @Test
    func pendingOperatorCancelledByUnknownKey() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dz")
        #expect(buffer.text == "hello world\nsecond line\nthird line\n")
    }

    // MARK: - Count Multiplication

    @Test
    func countTimesCountMultipliesMotion() {
        // 2d3w should delete 6 words worth (counts multiply).
        buffer = VimTextBufferMock(text: "a b c d e f g\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2d3w")
        #expect(buffer.text == "g\n", "2d3w should delete 6 words (2*3)")
    }

    // MARK: - Register After Delete (Default Register)

    @Test
    func deleteAndPasteRoundTrip() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw")
        #expect(buffer.text == "world\nsecond line\nthird line\n")
        key("P", shift: true)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "Deleted text should round-trip through P")
    }

    // MARK: - Motions after an operator, as Vim takes them

    private func make(_ text: String, at offset: Int) {
        buffer = VimTextBufferMock(text: text)
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
    }

    @Test("d% deletes through the matching bracket")
    func dPercentDeletesThroughTheMatchingBracket() {
        make("a (b c) d\n", at: 2)
        keys("d%")
        #expect(buffer.text == "a  d\n")
        #expect(engine.register.text == "(b c)")
    }

    @Test("d% from before the bracket takes the text up to it")
    func dPercentFromBeforeTheBracket() {
        make("a (b c) d\n", at: 0)
        keys("d%")
        #expect(buffer.text == " d\n")
    }

    @Test("c% changes the bracketed text")
    func cPercentChangesTheBracketedText() {
        make("a (b c) d\n", at: 2)
        keys("c%")
        #expect(buffer.text == "a  d\n")
        #expect(engine.mode == .insert)
        #expect(pos == 2)
    }

    @Test("y% yanks without moving")
    func yPercentYanks() {
        make("a (b c) d\n", at: 0)
        keys("y%")
        #expect(buffer.text == "a (b c) d\n")
        #expect(engine.register.text == "a (b c)")
        #expect(pos == 0)
    }

    @Test("d% with no bracket ends the command")
    func dPercentWithNoBracketEndsTheCommand() {
        make("a b c d\n", at: 0)
        keys("d%w")
        #expect(buffer.text == "a b c d\n")
        #expect(pos == 2)
    }

    @Test("A key that is not a motion ends the operator")
    func nonMotionKeyEndsTheOperator() {
        make("one two\n", at: 0)
        keys("dxw")
        #expect(buffer.text == "one two\n")
        #expect(pos == 4)
    }

    @Test("dn deletes to the next match")
    func dnDeletesToTheNextMatch() {
        make("foo bar foo baz\n", at: 0)
        keys("/foo\r0dn")
        #expect(buffer.text == "foo baz\n")
        #expect(engine.register.text == "foo bar ")
    }

    @Test("d} from a line start takes the paragraph's lines")
    func dBraceFromLineStartIsLinewise() {
        make("aaa\nbbb\n\nccc\n", at: 0)
        keys("d}")
        #expect(buffer.text == "\nccc\n")
        #expect(engine.register.text == "aaa\nbbb\n")
        #expect(engine.register.isLinewise)
    }

    @Test("d} from inside a line stops before the line break")
    func dBraceFromInsideALine() {
        make("aaa\nbbb\n\nccc\n", at: 1)
        keys("d}")
        #expect(buffer.text == "a\n\nccc\n")
        #expect(engine.register.text == "aa\nbbb")
        #expect(!engine.register.isLinewise)
    }

    @Test("d} on the last paragraph takes its lines")
    func dBraceOnTheLastParagraph() {
        make("aaa\nbbb\n", at: 0)
        keys("d}")
        #expect(buffer.text == "")
        #expect(engine.register.isLinewise)
    }

    @Test("d'a deletes the lines through the mark")
    func dQuoteMarkIsLinewise() {
        make("aaa\nbbb\nccc\n", at: 8)
        keys("magg")
        keys("d'a")
        #expect(buffer.text == "")
        #expect(engine.register.text == "aaa\nbbb\nccc\n")
    }

    @Test("d`a deletes up to the mark")
    func dBacktickMarkIsExclusive() {
        make("aaa\nbbb\nccc\n", at: 5)
        keys("magg")
        keys("d`a")
        #expect(buffer.text == "bb\nccc\n")
    }

    @Test("d'a with the mark unset ends the command")
    func dQuoteUnsetMarkEndsTheCommand() {
        make("aaa bbb\n", at: 0)
        keys("d'aw")
        #expect(buffer.text == "aaa bbb\n")
        #expect(pos == 4)
    }

    @Test("dL deletes to the last visible line")
    func dLDeletesToTheLastVisibleLine() {
        make("aaa\nbbb\nccc\n", at: 0)
        keys("d")
        key("L", shift: true)
        #expect(buffer.text == "")
    }

    @Test("db at a line start keeps the line break")
    func dbAtLineStartKeepsTheLineBreak() {
        make("foo bar\nbaz\n", at: 8)
        keys("db")
        #expect(buffer.text == "foo \nbaz\n")
        #expect(engine.register.text == "bar")
    }

    @Test("dW on the last WORD of a line stops at the line end")
    func dBigWOnTheLastWordStopsAtTheLineEnd() {
        make("foo b.r\n  baz\n", at: 4)
        keys("d")
        key("W", shift: true)
        #expect(buffer.text == "foo \n  baz\n")
    }

    @Test("dw on an empty line deletes the line")
    func dwOnAnEmptyLineDeletesIt() {
        make("aaa\n\nbbb\n", at: 4)
        keys("dw")
        #expect(buffer.text == "aaa\nbbb\n")
    }

    @Test("cw on a word changes to its end, not the space after")
    func cwChangesToTheWordEnd() {
        make("foo bar baz\n", at: 0)
        keys("cw")
        #expect(buffer.text == " bar baz\n")
        #expect(engine.mode == .insert)
    }

    @Test("2cw changes two words, not the space after the second")
    func cwWithCount() {
        make("foo bar baz\n", at: 0)
        keys("2cw")
        #expect(buffer.text == " baz\n")
    }

    @Test("cw on blanks changes them up to the next word")
    func cwOnBlanks() {
        make("foo   bar\n", at: 4)
        keys("cw")
        #expect(buffer.text == "foo bar\n")
    }

    @Test("cj leaves one empty line to type on")
    func cjLeavesALine() {
        make("a\nb\nc\n", at: 0)
        keys("cj")
        #expect(buffer.text == "\nc\n")
        #expect(engine.mode == .insert)
        #expect(pos == 0)
    }

    @Test("dj on the last line deletes nothing")
    func djOnTheLastLineFails() {
        make("aaa\nbbb\n", at: 4)
        keys("djx")
        #expect(buffer.text == "aaa\nbb\n")
    }

    @Test(">b from a line start shifts only the line the motion covers")
    func indentBackwardWordFromALineStart() {
        make("foo bar\nbaz\n", at: 8)
        keys(">b")
        #expect(buffer.text == "    foo bar\nbaz\n")
    }

    @Test(">w shifts the whole line")
    func indentWithACharacterMotionShiftsTheLine() {
        make("hello world\n", at: 6)
        keys(">w")
        #expect(buffer.text == "    hello world\n")
    }
}

// swiftlint:enable file_length type_body_length
