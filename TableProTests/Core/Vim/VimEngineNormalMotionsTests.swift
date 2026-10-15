//
//  VimEngineNormalMotionsTests.swift
//  TableProTests
//
//  Specification tests for cursor motions in Normal mode.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineNormalMotionsTests {
    // Standard test buffer:
    // Line 0: "hello world\n"  offsets  0..11   (newline at 11, content end at 10 = 'd')
    // Line 1: "second line\n"  offsets 12..23   (newline at 23, content end at 22 = 'e')
    // Line 2: "third line\n"   offsets 24..34   (newline at 34, content end at 33 = 'e')
    // Total length: 35
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

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - h / l (Character Motions)

    @Test
    func hMovesLeftByOne() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("h")
        #expect(pos == 4)
    }

    @Test
    func hStopsAtLineStart() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("h")
        #expect(pos == 12, "h must not cross line boundary backward")
    }

    @Test
    func hStopsAtBufferStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("h")
        #expect(pos == 0)
    }

    @Test
    func hWithCount() {
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("5h")
        #expect(pos == 3)
    }

    @Test
    func hCountClampedToLineStart() {
        buffer.setSelectedRange(NSRange(location: 14, length: 0))
        keys("99h")
        #expect(pos == 12, "h with large count must clamp to start of current line")
    }

    @Test
    func lMovesRightByOne() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        #expect(pos == 1)
    }

    @Test
    func lStopsBeforeNewline() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("l")
        #expect(pos == 10, "l must not move onto or past the line-terminating newline")
    }

    @Test
    func lWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("4l")
        #expect(pos == 4)
    }

    @Test
    func lCountClampedToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("99l")
        #expect(pos == 10, "l with large count clamps to last content char of line")
    }

    // MARK: - j / k (Line Motions) and Goal Column

    @Test
    func jMovesDownOneLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("j")
        #expect(pos == 12)
    }

    @Test
    func jPreservesColumn() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0)) // line 0 col 5
        keys("j")
        #expect(pos == 17, "j should preserve current column when moving down")
    }

    @Test
    func jStaysOnLastLine() {
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        keys("j")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 2, "j on last line stays on last line")
    }

    @Test
    func jWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2j")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 2)
    }

    @Test
    func kMovesUpOneLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("k")
        #expect(pos == 0)
    }

    @Test
    func kPreservesColumn() {
        buffer.setSelectedRange(NSRange(location: 18, length: 0)) // line 1 col 6
        keys("k")
        #expect(pos == 6, "k should preserve current column when moving up")
    }

    @Test
    func kStaysOnFirstLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("k")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 0)
    }

    @Test
    func kWithCount() {
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        keys("2k")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 0)
    }

    @Test
    func jGoalColumnSurvivesShortLines() {
        // Move to col 10 on line 0, j onto a short line, then j onto a long line again.
        // Vim's "goal column" semantics: column 10 is remembered even when
        // intermediate lines are shorter than 10.
        buffer = VimTextBufferMock(text: "0123456789xx\nshort\n0123456789xx\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0)) // line 0, col 10 ('x')
        keys("j") // line 1 is "short" — clamped to col 4
        keys("j") // line 2 — should snap back to col 10
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 2)
        #expect(col == 10, "Goal column should snap back to 10 on a long-enough line")
    }

    @Test
    func hResetsGoalColumn() {
        // After h, the goal column should be cleared.
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("jh")
        // Now at line 1, col reduced by 1. Subsequent j should not snap back to col 10.
        keys("j")
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 2)
        #expect(col < 10, "h should reset goal column so subsequent j uses new column")
    }

    // MARK: - Word Motions: w / W

    @Test
    func wMovesToNextWordStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        #expect(pos == 6, "w should move from 'h' in 'hello' to 'w' in 'world'")
    }

    @Test
    func wAcrossLineBoundary() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0)) // 'w' in 'world'
        keys("w")
        #expect(pos == 12, "w should cross newline to next word")
    }

    @Test
    func wStopsAtPunctuation() {
        buffer = VimTextBufferMock(text: "hello,world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        #expect(pos == 5, "w should stop at the punctuation as a new word")
    }

    @Test
    func wWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3w")
        #expect(pos == 19, "3w advances three word-starts: hello → world → second → line (offset 19)")
    }

    @Test
    func wAtLastWordOfBufferStaysOnLastChar() {
        // "SELECT * FROM users;" — no next word after ';'. Pressing w from ';' must
        // not advance past the last char; the cursor stays on ';'.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 19, length: 0))
        keys("w")
        #expect(pos == 19, "w from the last word of the buffer must stay on the last content char")
    }

    @Test
    func wAtLastWordSingleLineWithoutNewline() {
        // Single-word buffer "hello" with no newline. w from 'h' should land on the
        // last content char 'o' (vim's last-word-on-last-line clamp).
        buffer = VimTextBufferMock(text: "hello")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        #expect(pos == 4, "w with no next word should land on the last content char, not past it")
    }

    @Test
    func wClampsToLastCharOnLineWithTrailingNewline() {
        // "hello\n" — single word followed by newline, no further content.
        buffer = VimTextBufferMock(text: "hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        #expect(pos == 4, "w on a single-word buffer with trailing newline lands on 'o'")
    }

    @Test
    func capitalWTreatsPunctuationAsWordChar() {
        // W (WORD) moves by whitespace-delimited tokens — punctuation is not a boundary.
        buffer = VimTextBufferMock(text: "hello,world foo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("W", shift: true)
        #expect(pos == 12, "W should skip past punctuation and land at next WORD")
    }

    @Test
    func capitalWWithCount() {
        buffer = VimTextBufferMock(text: "a.b c.d e.f g.h\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        key("W", shift: true)
        #expect(pos == 8, "2W should advance past two WORDs")
    }

    // MARK: - Word Motions: b / B

    @Test
    func bMovesToPreviousWordStart() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("b")
        #expect(pos == 0)
    }

    @Test
    func bFromMidWordGoesToWordStart() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0)) // 'l' in 'hello'
        keys("b")
        #expect(pos == 0, "b from mid-word should land at the start of the same word")
    }

    @Test
    func bAtStartOfBufferStaysPut() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("b")
        #expect(pos == 0)
    }

    @Test
    func bAcrossLineBoundary() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0)) // start of 'second'
        keys("b")
        #expect(pos == 6, "b from line start should cross newline to previous word")
    }

    @Test
    func bWithCount() {
        buffer.setSelectedRange(NSRange(location: 17, length: 0))
        keys("3b")
        #expect(pos == 0, "3b should skip back three word starts")
    }

    @Test
    func capitalBTreatsPunctuationAsWordChar() {
        buffer = VimTextBufferMock(text: "hello,world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        key("B", shift: true)
        #expect(pos == 0, "B should treat 'hello,world' as one WORD")
    }

    // MARK: - Word End: e / E / ge / gE

    @Test
    func eMovesToEndOfCurrentWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("e")
        #expect(pos == 4, "e from 'h' should land on 'o' (end of 'hello')")
    }

    @Test
    func eAtWordEndJumpsToNextWordEnd() {
        buffer.setSelectedRange(NSRange(location: 4, length: 0)) // 'o' at end of 'hello'
        keys("e")
        #expect(pos == 10, "e from end of word should jump to end of next word")
    }

    @Test
    func eWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3e")
        #expect(pos == 17, "3e from 'hello' should land at end of 'second' (offset 17)")
    }

    @Test
    func capitalEIgnoresPunctuation() {
        buffer = VimTextBufferMock(text: "a.b.c word\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("E", shift: true)
        #expect(pos == 4, "E should land at end of WORD 'a.b.c'")
    }

    @Test
    func gEMovesToPreviousWordEnd() {
        // ge is the backward analog of e.
        buffer.setSelectedRange(NSRange(location: 12, length: 0)) // start of 'second'
        keys("ge")
        #expect(pos == 10, "ge should land at the end of the previous word ('d' in 'world')")
    }

    @Test
    func gEWithCount() {
        buffer.setSelectedRange(NSRange(location: 17, length: 0))
        keys("2ge")
        #expect(pos == 4, "2ge from mid-word should skip two word-ends backward")
    }

    @Test
    func capitalGEIgnoresPunctuation() {
        buffer = VimTextBufferMock(text: "a.b.c word\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0)) // 'w' in 'word'
        keys("g")
        key("E", shift: true)
        #expect(pos == 4, "gE should land at end of WORD 'a.b.c'")
    }

    // MARK: - Line Motions: 0 / $ / ^ / _

    @Test
    func zeroGoesToLineStart() {
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("0")
        #expect(pos == 0)
    }

    @Test
    func zeroIgnoresLeadingWhitespace() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("0")
        #expect(pos == 0, "0 should land at column 0 even when leading whitespace exists")
    }

    @Test
    func dollarGoesToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("$")
        #expect(pos == 10, "$ on 'hello world\\n' should land on 'd' (offset 10)")
    }

    @Test
    func dollarOnLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "hello")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("$")
        #expect(pos == 4, "$ on the last line without a newline should land on the last char")
    }

    @Test
    func caretGoesToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("^")
        #expect(pos == 3, "^ should skip leading whitespace and land on 'h'")
    }

    @Test
    func caretOnBlankLineGoesToLineStart() {
        buffer = VimTextBufferMock(text: "hello\n\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("^")
        #expect(pos == 6, "^ on blank line should stay at line start")
    }

    @Test
    func underscoreGoesToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "\t\thello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("_")
        #expect(pos == 2, "_ should skip tabs and land on 'h'")
    }

    // MARK: - Document Motions: gg / G

    @Test
    func gGGoesToDocumentStart() {
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("gg")
        #expect(pos == 0)
    }

    @Test
    func gGGoesToFirstNonBlankOnFirstLine() {
        buffer = VimTextBufferMock(text: "   hello\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("gg")
        #expect(pos == 3, "gg should land on the first non-blank of line 1")
    }

    @Test
    func capitalGGoesToLastLineFirstNonBlank() {
        buffer = VimTextBufferMock(text: "one\ntwo\n   three\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("G", shift: true)
        #expect(pos == 11, "G should land on first non-blank of last line ('t' at offset 11)")
    }

    @Test
    func countGGoesToSpecificLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        key("G", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 1, "2G should land on line 2 (0-indexed line 1)")
    }

    @Test
    func countGGGoesToSpecificLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2gg")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 1)
    }

    @Test
    func countGClampedAtLastLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("999")
        key("G", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 2, "Count beyond last line should clamp to last line")
    }

    // MARK: - Screen Motions: H / M / L

    @Test
    func hHomeMovesToTopOfScreen() {
        // In the engine (no scroll concept), H should move to the first line of the buffer.
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        key("H", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 0, "H should move to the top of the visible/buffer range")
    }

    @Test
    func lLastMovesToBottomOfScreen() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("L", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 2, "L should move to the bottom of the visible/buffer range")
    }

    @Test
    func mMiddleMovesToMiddleOfScreen() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("M", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 1, "M should move to the middle of the visible/buffer range")
    }

    // MARK: - Matching: %

    @Test
    func percentJumpsToMatchingParen() {
        buffer = VimTextBufferMock(text: "(hello)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        #expect(pos == 6, "% on '(' should jump to matching ')'")
    }

    @Test
    func percentJumpsBackToOpenParen() {
        buffer = VimTextBufferMock(text: "(hello)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("%")
        #expect(pos == 0, "% on ')' should jump back to '('")
    }

    @Test
    func percentMatchesNestedBrackets() {
        buffer = VimTextBufferMock(text: "(a(b)c)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        #expect(pos == 6, "% on outer '(' should jump to matching outer ')'")
    }

    @Test
    func percentMatchesCurlyBraces() {
        buffer = VimTextBufferMock(text: "{a}\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        #expect(pos == 2)
    }

    @Test
    func percentMatchesSquareBrackets() {
        buffer = VimTextBufferMock(text: "[a]\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        #expect(pos == 2)
    }

    // MARK: - Pending g Cancellation

    @Test
    func pendingGCancelledByUnknownKey() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("g")
        keys("z") // unknown — should consume and clear pending g
        // Subsequent l should move 1 (not be interpreted as part of a g sequence)
        keys("l")
        #expect(pos == 6)
    }

    @Test
    func pendingGCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("g")
        _ = engine.process("\u{1B}", shift: false)
        keys("l")
        #expect(pos == 6)
    }

    // MARK: - Empty Buffer Safety

    @Test
    func motionsOnEmptyBufferDoNotCrash() {
        buffer = VimTextBufferMock(text: "")
        engine = VimEngine(buffer: buffer)
        keys("hjklwbe0$^_")
        keys("gg")
        key("G", shift: true)
        #expect(pos == 0)
        #expect(buffer.text == "")
    }
}

// swiftlint:enable file_length type_body_length
