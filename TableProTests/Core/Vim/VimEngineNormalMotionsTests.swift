//
//  VimEngineNormalMotionsTests.swift
//  TableProTests
//
//  Specification tests for cursor motions in Normal mode.
//

import XCTest
import TableProPluginKit
@testable import TablePro

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineNormalMotionsTests: XCTestCase {
    // Standard test buffer:
    // Line 0: "hello world\n"  offsets  0..11   (newline at 11, content end at 10 = 'd')
    // Line 1: "second line\n"  offsets 12..23   (newline at 23, content end at 22 = 'e')
    // Line 2: "third line\n"   offsets 24..34   (newline at 34, content end at 33 = 'e')
    // Total length: 35
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - h / l (Character Motions)

    func testHMovesLeftByOne() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("h")
        XCTAssertEqual(pos, 4)
    }

    func testHStopsAtLineStart() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("h")
        XCTAssertEqual(pos, 12, "h must not cross line boundary backward")
    }

    func testHStopsAtBufferStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("h")
        XCTAssertEqual(pos, 0)
    }

    func testHWithCount() {
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("5h")
        XCTAssertEqual(pos, 3)
    }

    func testHCountClampedToLineStart() {
        buffer.setSelectedRange(NSRange(location: 14, length: 0))
        keys("99h")
        XCTAssertEqual(pos, 12, "h with large count must clamp to start of current line")
    }

    func testLMovesRightByOne() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        XCTAssertEqual(pos, 1)
    }

    func testLStopsBeforeNewline() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("l")
        XCTAssertEqual(pos, 10, "l must not move onto or past the line-terminating newline")
    }

    func testLWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("4l")
        XCTAssertEqual(pos, 4)
    }

    func testLCountClampedToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("99l")
        XCTAssertEqual(pos, 10, "l with large count clamps to last content char of line")
    }

    // MARK: - j / k (Line Motions) and Goal Column

    func testJMovesDownOneLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("j")
        XCTAssertEqual(pos, 12)
    }

    func testJPreservesColumn() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0)) // line 0 col 5
        keys("j")
        XCTAssertEqual(pos, 17, "j should preserve current column when moving down")
    }

    func testJStaysOnLastLine() {
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        keys("j")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 2, "j on last line stays on last line")
    }

    func testJWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2j")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 2)
    }

    func testKMovesUpOneLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("k")
        XCTAssertEqual(pos, 0)
    }

    func testKPreservesColumn() {
        buffer.setSelectedRange(NSRange(location: 18, length: 0)) // line 1 col 6
        keys("k")
        XCTAssertEqual(pos, 6, "k should preserve current column when moving up")
    }

    func testKStaysOnFirstLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("k")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 0)
    }

    func testKWithCount() {
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        keys("2k")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 0)
    }

    func testJGoalColumnSurvivesShortLines() {
        // Move to col 10 on line 0, j onto a short line, then j onto a long line again.
        // Vim's "goal column" semantics: column 10 is remembered even when
        // intermediate lines are shorter than 10.
        buffer = VimTextBufferMock(text: "0123456789xx\nshort\n0123456789xx\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0)) // line 0, col 10 ('x')
        keys("j") // line 1 is "short" — clamped to col 4
        keys("j") // line 2 — should snap back to col 10
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 2)
        XCTAssertEqual(col, 10, "Goal column should snap back to 10 on a long-enough line")
    }

    func testHResetsGoalColumn() {
        // After h, the goal column should be cleared.
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("jh")
        // Now at line 1, col reduced by 1. Subsequent j should not snap back to col 10.
        keys("j")
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 2)
        XCTAssertLessThan(col, 10, "h should reset goal column so subsequent j uses new column")
    }

    // MARK: - Word Motions: w / W

    func testWMovesToNextWordStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        XCTAssertEqual(pos, 6, "w should move from 'h' in 'hello' to 'w' in 'world'")
    }

    func testWAcrossLineBoundary() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0)) // 'w' in 'world'
        keys("w")
        XCTAssertEqual(pos, 12, "w should cross newline to next word")
    }

    func testWStopsAtPunctuation() {
        buffer = VimTextBufferMock(text: "hello,world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        XCTAssertEqual(pos, 5, "w should stop at the punctuation as a new word")
    }

    func testWWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3w")
        XCTAssertEqual(pos, 19, "3w advances three word-starts: hello → world → second → line (offset 19)")
    }

    func testWAtLastWordOfBufferStaysOnLastChar() {
        // "SELECT * FROM users;" — no next word after ';'. Pressing w from ';' must
        // not advance past the last char; the cursor stays on ';'.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 19, length: 0))
        keys("w")
        XCTAssertEqual(pos, 19, "w from the last word of the buffer must stay on the last content char")
    }

    func testWAtLastWordSingleLineWithoutNewline() {
        // Single-word buffer "hello" with no newline. w from 'h' should land on the
        // last content char 'o' (vim's last-word-on-last-line clamp).
        buffer = VimTextBufferMock(text: "hello")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        XCTAssertEqual(pos, 4, "w with no next word should land on the last content char, not past it")
    }

    func testWClampsToLastCharOnLineWithTrailingNewline() {
        // "hello\n" — single word followed by newline, no further content.
        buffer = VimTextBufferMock(text: "hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        XCTAssertEqual(pos, 4, "w on a single-word buffer with trailing newline lands on 'o'")
    }

    func testCapitalWTreatsPunctuationAsWordChar() {
        // W (WORD) moves by whitespace-delimited tokens — punctuation is not a boundary.
        buffer = VimTextBufferMock(text: "hello,world foo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("W", shift: true)
        XCTAssertEqual(pos, 12, "W should skip past punctuation and land at next WORD")
    }

    func testCapitalWWithCount() {
        buffer = VimTextBufferMock(text: "a.b c.d e.f g.h\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        key("W", shift: true)
        XCTAssertEqual(pos, 8, "2W should advance past two WORDs")
    }

    // MARK: - Word Motions: b / B

    func testBMovesToPreviousWordStart() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("b")
        XCTAssertEqual(pos, 0)
    }

    func testBFromMidWordGoesToWordStart() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0)) // 'l' in 'hello'
        keys("b")
        XCTAssertEqual(pos, 0, "b from mid-word should land at the start of the same word")
    }

    func testBAtStartOfBufferStaysPut() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("b")
        XCTAssertEqual(pos, 0)
    }

    func testBAcrossLineBoundary() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0)) // start of 'second'
        keys("b")
        XCTAssertEqual(pos, 6, "b from line start should cross newline to previous word")
    }

    func testBWithCount() {
        buffer.setSelectedRange(NSRange(location: 17, length: 0))
        keys("3b")
        XCTAssertEqual(pos, 0, "3b should skip back three word starts")
    }

    func testCapitalBTreatsPunctuationAsWordChar() {
        buffer = VimTextBufferMock(text: "hello,world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        key("B", shift: true)
        XCTAssertEqual(pos, 0, "B should treat 'hello,world' as one WORD")
    }

    // MARK: - Word End: e / E / ge / gE

    func testEMovesToEndOfCurrentWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("e")
        XCTAssertEqual(pos, 4, "e from 'h' should land on 'o' (end of 'hello')")
    }

    func testEAtWordEndJumpsToNextWordEnd() {
        buffer.setSelectedRange(NSRange(location: 4, length: 0)) // 'o' at end of 'hello'
        keys("e")
        XCTAssertEqual(pos, 10, "e from end of word should jump to end of next word")
    }

    func testEWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3e")
        XCTAssertEqual(pos, 17, "3e from 'hello' should land at end of 'second' (offset 17)")
    }

    func testCapitalEIgnoresPunctuation() {
        buffer = VimTextBufferMock(text: "a.b.c word\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("E", shift: true)
        XCTAssertEqual(pos, 4, "E should land at end of WORD 'a.b.c'")
    }

    func testGEMovesToPreviousWordEnd() {
        // ge is the backward analog of e.
        buffer.setSelectedRange(NSRange(location: 12, length: 0)) // start of 'second'
        keys("ge")
        XCTAssertEqual(pos, 10, "ge should land at the end of the previous word ('d' in 'world')")
    }

    func testGEWithCount() {
        buffer.setSelectedRange(NSRange(location: 17, length: 0))
        keys("2ge")
        XCTAssertEqual(pos, 4, "2ge from mid-word should skip two word-ends backward")
    }

    func testCapitalGEIgnoresPunctuation() {
        buffer = VimTextBufferMock(text: "a.b.c word\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0)) // 'w' in 'word'
        keys("g")
        key("E", shift: true)
        XCTAssertEqual(pos, 4, "gE should land at end of WORD 'a.b.c'")
    }

    // MARK: - Line Motions: 0 / $ / ^ / _

    func testZeroGoesToLineStart() {
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("0")
        XCTAssertEqual(pos, 0)
    }

    func testZeroIgnoresLeadingWhitespace() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("0")
        XCTAssertEqual(pos, 0, "0 should land at column 0 even when leading whitespace exists")
    }

    func testDollarGoesToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("$")
        XCTAssertEqual(pos, 10, "$ on 'hello world\\n' should land on 'd' (offset 10)")
    }

    func testDollarOnLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "hello")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("$")
        XCTAssertEqual(pos, 4, "$ on the last line without a newline should land on the last char")
    }

    func testCaretGoesToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("^")
        XCTAssertEqual(pos, 3, "^ should skip leading whitespace and land on 'h'")
    }

    func testCaretOnBlankLineGoesToLineStart() {
        buffer = VimTextBufferMock(text: "hello\n\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("^")
        XCTAssertEqual(pos, 6, "^ on blank line should stay at line start")
    }

    func testUnderscoreGoesToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "\t\thello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("_")
        XCTAssertEqual(pos, 2, "_ should skip tabs and land on 'h'")
    }

    // MARK: - Document Motions: gg / G

    func testGGGoesToDocumentStart() {
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("gg")
        XCTAssertEqual(pos, 0)
    }

    func testGGGoesToFirstNonBlankOnFirstLine() {
        buffer = VimTextBufferMock(text: "   hello\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("gg")
        XCTAssertEqual(pos, 3, "gg should land on the first non-blank of line 1")
    }

    func testCapitalGGoesToLastLineFirstNonBlank() {
        buffer = VimTextBufferMock(text: "one\ntwo\n   three\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("G", shift: true)
        XCTAssertEqual(pos, 11, "G should land on first non-blank of last line ('t' at offset 11)")
    }

    func testCountGGoesToSpecificLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        key("G", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 1, "2G should land on line 2 (0-indexed line 1)")
    }

    func testCountGGGoesToSpecificLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2gg")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 1)
    }

    func testCountGClampedAtLastLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("999")
        key("G", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 2, "Count beyond last line should clamp to last line")
    }

    // MARK: - Screen Motions: H / M / L

    func testHHomeMovesToTopOfScreen() {
        // In the engine (no scroll concept), H should move to the first line of the buffer.
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        key("H", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 0, "H should move to the top of the visible/buffer range")
    }

    func testLLastMovesToBottomOfScreen() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("L", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 2, "L should move to the bottom of the visible/buffer range")
    }

    func testMMiddleMovesToMiddleOfScreen() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("M", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 1, "M should move to the middle of the visible/buffer range")
    }

    // MARK: - Matching: %

    func testPercentJumpsToMatchingParen() {
        buffer = VimTextBufferMock(text: "(hello)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        XCTAssertEqual(pos, 6, "% on '(' should jump to matching ')'")
    }

    func testPercentJumpsBackToOpenParen() {
        buffer = VimTextBufferMock(text: "(hello)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("%")
        XCTAssertEqual(pos, 0, "% on ')' should jump back to '('")
    }

    func testPercentMatchesNestedBrackets() {
        buffer = VimTextBufferMock(text: "(a(b)c)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        XCTAssertEqual(pos, 6, "% on outer '(' should jump to matching outer ')'")
    }

    func testPercentMatchesCurlyBraces() {
        buffer = VimTextBufferMock(text: "{a}\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        XCTAssertEqual(pos, 2)
    }

    func testPercentMatchesSquareBrackets() {
        buffer = VimTextBufferMock(text: "[a]\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("%")
        XCTAssertEqual(pos, 2)
    }

    // MARK: - Pending g Cancellation

    func testPendingGCancelledByUnknownKey() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("g")
        keys("z") // unknown — should consume and clear pending g
        // Subsequent l should move 1 (not be interpreted as part of a g sequence)
        keys("l")
        XCTAssertEqual(pos, 6)
    }

    func testPendingGCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("g")
        _ = engine.process("\u{1B}", shift: false)
        keys("l")
        XCTAssertEqual(pos, 6)
    }

    // MARK: - Empty Buffer Safety

    func testMotionsOnEmptyBufferDoNotCrash() {
        buffer = VimTextBufferMock(text: "")
        engine = VimEngine(buffer: buffer)
        keys("hjklwbe0$^_")
        keys("gg")
        key("G", shift: true)
        XCTAssertEqual(pos, 0)
        XCTAssertEqual(buffer.text, "")
    }
}

// swiftlint:enable file_length type_body_length
