//
//  VimVisualModeTests.swift
//  TableProTests
//
//  Comprehensive visual mode tests — defines correct Vim selection behavior
//

import XCTest
import TableProPluginKit
@testable import TablePro

// swiftlint:disable file_length type_body_length

@MainActor
final class VimVisualModeTests: XCTestCase {
    // Buffer layout:
    // "hello world\nsecond line\nthird line\n"
    //  0         1111111111222222222233333
    //  0123456789012345678901234567890123 4
    //
    // Line 0: "hello world\n"  — offsets 0..11   (length 12)
    // Line 1: "second line\n"  — offsets 12..23  (length 12)
    // Line 2: "third line\n"   — offsets 24..34  (length 11)
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

    // MARK: - Helpers

    private func keys(_ chars: String) {
        for char in chars {
            _ = engine.process(char, shift: false)
        }
    }

    private func key(_ char: Character, shift: Bool = false) -> Bool {
        engine.process(char, shift: shift)
    }

    private func escape() {
        _ = engine.process("\u{1B}", shift: false)
    }

    // MARK: - Visual Mode Entry/Exit

    func testVEntersVisualMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    func testVSetsInitialSelectionLength1() {
        // Pressing v at position 3 should select 1 char: "l"
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        _ = key("v")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 3)
        XCTAssertEqual(sel.length, 1)
        XCTAssertEqual(buffer.string(in: sel), "l")
    }

    func testEscapeExitsVisualModeToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
        escape()
        XCTAssertEqual(engine.mode, .normal)
    }

    func testEscapeResetsSelectionToZeroLength() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("l")
        // Selection should be non-zero before escape
        XCTAssertGreaterThan(buffer.selectedRange().length, 0)
        escape()
        XCTAssertEqual(buffer.selectedRange().length, 0)
    }

    func testVInVisualModeExitsToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
        _ = key("v") // Toggle off
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(buffer.selectedRange().length, 0)
    }

    func testModeChangeCallbackFiresOnVisualEntry() {
        var receivedMode: VimMode?
        engine.onModeChange = { mode in
            receivedMode = mode
        }
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        XCTAssertEqual(receivedMode, .visual(linewise: false))
    }

    func testModeChangeCallbackFiresOnVisualExit() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        var receivedMode: VimMode?
        engine.onModeChange = { mode in
            receivedMode = mode
        }
        escape()
        XCTAssertEqual(receivedMode, .normal)
    }

    // MARK: - Visual Mode Motions (character-wise)

    func testVisualLExtendsSelectionRight() {
        // At pos 0: v selects "h" (0,1), l extends to "he" (0,2)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 2)
        XCTAssertEqual(buffer.string(in: sel), "he")
    }

    func testVisualHExtendsSelectionLeft() {
        // At pos 5: v selects " " (5,1), h extends backward to "o " (4,2)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("v")
        _ = key("h")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 4)
        XCTAssertEqual(sel.length, 2)
        XCTAssertEqual(buffer.string(in: sel), "o ")
    }

    func testVisualLLExtendsSelectionTwoRight() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("l")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 3)
        XCTAssertEqual(buffer.string(in: sel), "hel")
    }

    func testVisualHFromMiddleSelectsBackward() {
        // At pos 6 ("w"), v selects "w", h moves cursor to 5
        // anchor=6, cursor=5, start=5, end=6, length = 6-5+1 = 2
        // So selection = (5, 2) = " w"
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        _ = key("v")
        _ = key("h")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 5)
        XCTAssertEqual(sel.length, 2)
        XCTAssertEqual(buffer.string(in: sel), " w")
    }

    func testVisualLWithCount() {
        // Visual mode does not process count prefix — digits are consumed as unknown keys.
        // So pressing "3" then "l" only does 1 l motion.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("3")
        _ = key("l")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        // Only 1 l motion executed (digit consumed as no-op)
        XCTAssertEqual(sel.length, 2)
        XCTAssertEqual(buffer.string(in: sel), "he")
    }

    func testVisualHWithCount() {
        // Same: count prefix not supported in visual mode, digit consumed as no-op
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("v")
        _ = key("3")
        _ = key("h")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 4)
        XCTAssertEqual(sel.length, 2)
    }

    func testVisualJExtendsSelectionDownward() {
        // At pos 0 line 0 col 0: v selects "h", j moves to line 1 col 0 = pos 12
        // anchor=0, cursor=12, selection = (0, 13) inclusive
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("j")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 13)
        XCTAssertEqual(buffer.string(in: sel), "hello world\ns")
    }

    func testVisualKExtendsSelectionUpward() {
        // At pos 15 (line 1 col 3 = "o" in "second"), v selects "o", k moves to line 0 col 3 = pos 3
        // anchor=15, cursor=3, start=3, end=15, length=15-3+1=13
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        _ = key("v")
        _ = key("k")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 3)
        XCTAssertEqual(sel.length, 13)
    }

    func testVisualJAtLastLine() {
        // At pos 28 (line 2 col 4 = "d" in "third"), j should stay on same line
        // (already on last line)
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        _ = key("v")
        let selBefore = buffer.selectedRange()
        _ = key("j")
        let selAfter = buffer.selectedRange()
        // Should still be on line 2. The cursor may move to clamped column on same line.
        XCTAssertEqual(selAfter.location, selBefore.location)
        XCTAssertEqual(selAfter.length, selBefore.length)
    }

    // MARK: - Visual Mode Word Motions

    func testVisualWExtendsToNextWord() {
        // At pos 0: v selects "h", w moves to word boundary = pos 6 ("w" of "world")
        // anchor=0, cursor=6, selection = (0, 7)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("w")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(buffer.string(in: sel), "hello w")
    }

    func testVisualBExtendsBackwardToWordStart() {
        // At pos 8 ("r" in "world"), v selects "r", b moves backward to word start = pos 6
        // anchor=8, cursor=6, start=6, end=8, length=8-6+1=3
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        _ = key("v")
        _ = key("b")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 6)
        XCTAssertEqual(buffer.string(in: sel), "wor")
    }

    func testVisualEExtendsToWordEnd() {
        // At pos 0: v selects "h", e moves to end of "hello" = pos 4
        // anchor=0, cursor=4, selection = (0, 5)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("e")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 5)
        XCTAssertEqual(buffer.string(in: sel), "hello")
    }

    // MARK: - Visual Mode Line Motions

    func testVisualZeroExtendsToLineStart() {
        // At pos 5 (" "): v selects " ", 0 moves to line start = pos 0
        // anchor=5, cursor=0, start=0, end=5, length=5-0+1=6
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("v")
        _ = key("0")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 6)
        XCTAssertEqual(buffer.string(in: sel), "hello ")
    }

    func testVisualDollarExtendsToLineEnd() {
        // At pos 0: v selects "h", $ moves to line end.
        // Line 0 ends with \n at pos 11, so $ goes to pos 11 (the \n itself)
        // anchor=0, cursor=11, selection = (0, 12) inclusive
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("$")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 12)
        XCTAssertEqual(buffer.string(in: sel), "hello world\n")
    }

    func testVisualGGExtendsToDocumentStart() {
        // At pos 15: v selects char, gg extends to pos 0
        // anchor=15, cursor=0, start=0, end=15, length=16
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        _ = key("v")
        keys("gg")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 16)
    }

    func testVisualGExtendsToDocumentEnd() {
        // At pos 0: v selects "h", G moves to max(0, buffer.length - 1) = 34
        // anchor=0, cursor=34, selection = (0, 35) since 34 < buffer.length
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("G", shift: true)
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        // cursor at max(0, 35-1) = 34, which is < buffer.length, so length = 34-0+1 = 35
        XCTAssertEqual(sel.location + sel.length, buffer.length)
        // Verify cursor is at max(0, buffer.length - 1), NOT buffer.length
        XCTAssertEqual(engine.cursorOffset, max(0, buffer.length - 1))
    }

    // MARK: - Visual Mode Operators (d, y, c)

    func testVisualDeleteRemovesSelectedText() {
        // v at 0 selects "h", l extends to "he", d deletes "he"
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("d")
        XCTAssertEqual(buffer.text, "llo world\nsecond line\nthird line\n")
    }

    func testVisualDeleteSetsRegister() {
        // Delete "he", then paste before to verify register contains exactly "he"
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("d")
        // After delete: text = "llo world\n...", cursor at 0
        // P pastes "he" at pos 0: "hello world\n..."
        _ = key("P", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    func testVisualDeleteReturnsToNormalMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("d")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVisualDeleteCursorPosition() {
        // After deleting "he" (pos 0-1), cursor should be at start of deleted region
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("d")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 0)
    }

    func testVisualYankCopiesSelectedText() {
        // Yank "he", then paste to verify register contains "he"
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("y")
        // After yank, cursor at pos 0. p pastes after cursor (inserts at pos 1).
        // "h" + "he" + "ello world..." = "hheello world..."
        _ = key("p")
        XCTAssertEqual(buffer.text, "hheello world\nsecond line\nthird line\n")
    }

    func testVisualYankReturnsToNormalMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("y")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVisualYankDoesNotModifyBuffer() {
        let originalText = buffer.text
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("e") // Select "hello"
        _ = key("y")
        XCTAssertEqual(buffer.text, originalText)
    }

    func testVisualYankThenPasteRestoresContent() {
        // Yank "hello" (ve at pos 0), then paste after cursor
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("e") // Select "hello" (pos 0-4, length 5)
        _ = key("y")
        // After yank, cursor at pos 0, selection length 0
        XCTAssertEqual(buffer.selectedRange().location, 0)
        XCTAssertEqual(buffer.selectedRange().length, 0)
        // p pastes after cursor: insert at pos 1 → "hhelloello world..."
        _ = key("p")
        XCTAssertEqual(buffer.text, "hhelloello world\nsecond line\nthird line\n")
    }

    func testVisualChangeDeletesAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("c")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "llo world\nsecond line\nthird line\n")
    }

    func testVisualChangeSetsRegister() {
        // Change "he", register should contain "he", then escape and paste to verify
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("c")
        // Now in insert mode. Escape back to normal.
        escape()
        // After escape from insert, cursor moves back 1 if possible.
        // Now paste to check register.
        _ = key("p")
        // Register contains "he" (characterwise). Paste after cursor.
        XCTAssertEqual(buffer.text, "lhelo world\nsecond line\nthird line\n",
            "Register should contain 'he' and paste should insert it at offset 1")
    }

    // MARK: - Visual Mode with Multiple Characters Selected

    func testVisualSelectMultipleThenDelete() {
        // v at pos 0 selects "h", l→"he", l→"hel", d deletes "hel"
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("l")
        _ = key("d")
        XCTAssertEqual(buffer.text, "lo world\nsecond line\nthird line\n")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVisualSelectWordThenYank() {
        // v at pos 0, e selects "hello" (pos 0-4), y yanks it
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("e")
        _ = key("y")
        // Buffer unchanged
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
        // Cursor at start of yanked region
        XCTAssertEqual(buffer.selectedRange().location, 0)
        XCTAssertEqual(buffer.selectedRange().length, 0)
    }

    func testVisualSelectBackwardThenDelete() {
        // At pos 6 ("w"), enter visual, b moves cursor backward to pos 0
        // anchor=6, cursor=0, selection = (0, 7) = "hello w"
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        _ = key("v")
        _ = key("b")
        _ = key("d")
        XCTAssertEqual(buffer.text, "orld\nsecond line\nthird line\n")
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - Visual Line Mode (V)

    func testVUpperEntersVisualLineMode() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("V", shift: true)
        XCTAssertEqual(engine.mode, .visual(linewise: true))
    }

    func testVisualLineModeSelectsFullLine() {
        // V at pos 5 (in "hello world\n") should select entire line 0
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("V", shift: true)
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 12) // "hello world\n"
        XCTAssertEqual(buffer.string(in: sel), "hello world\n")
    }

    func testVisualLineModeJExtendsToNextLine() {
        // V at pos 5, j extends to include line 1
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("V", shift: true)
        _ = key("j")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 24) // "hello world\nsecond line\n"
        XCTAssertEqual(buffer.string(in: sel), "hello world\nsecond line\n")
    }

    func testVisualLineModeKExtendsUpward() {
        // V at pos 15 (line 1), k extends upward to include line 0
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        _ = key("V", shift: true)
        _ = key("k")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 24) // lines 0+1
    }

    func testVisualLineDeleteRemovesWholeLine() {
        // V at pos 0 selects line 0, d deletes it
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("V", shift: true)
        _ = key("d")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVisualLineYankIsLinewise() {
        // V at pos 0, y yanks line 0. Then p should paste as a new line below.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("V", shift: true)
        _ = key("y")
        // Buffer unchanged
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
        // Paste below (p after linewise yank inserts a new line after current line)
        _ = key("p")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nthird line\n")
    }

    func testVisualLineThenPasteInsertsAsNewLine() {
        // V, y line 1, move to line 0, p should paste below line 0
        buffer.setSelectedRange(NSRange(location: 15, length: 0)) // line 1
        _ = key("V", shift: true)
        _ = key("y")
        // Cursor back at line 1 start after yank
        // Move to line 0
        _ = key("k")
        _ = key("p")
        // "second line\n" pasted after line 0
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nsecond line\nthird line\n")
    }

    func testVisualLineDeleteMultipleLines() {
        // V at pos 0 selects line 0, j extends to line 1, d deletes both
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("V", shift: true)
        _ = key("j")
        _ = key("d")
        XCTAssertEqual(buffer.text, "third line\n")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVUpperInVisualLineModeExitsToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("V", shift: true)
        XCTAssertEqual(engine.mode, .visual(linewise: true))
        _ = key("V", shift: true) // Toggle off
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(buffer.selectedRange().length, 0)
    }

    // MARK: - Visual Mode Edge Cases

    func testVisualModeAtStartOfBuffer() {
        // v at pos 0, h should not go negative — stays at 0
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("h")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 1) // Still selecting just "h"
    }

    func testVisualModeAtEndOfBuffer() {
        // Position at last char (pos 34 = "\n")
        buffer.setSelectedRange(NSRange(location: 34, length: 0))
        _ = key("v")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 34)
        XCTAssertEqual(sel.length, 1)
        // l should not extend past buffer end
        _ = key("l")
        let sel2 = buffer.selectedRange()
        // cursor moves to 35 = buffer.length, but updateVisualSelection:
        // start=34, end=35, length = 35 - 34 + (35 < 35 ? 1 : 0) = 1 + 0 = 1
        XCTAssertEqual(sel2.location, 34)
        XCTAssertEqual(sel2.length, 1)
    }

    func testVisualModeEmptyBuffer() {
        let emptyBuffer = VimTextBufferMock(text: "")
        let eng = VimEngine(buffer: emptyBuffer)
        _ = eng.process("v", shift: false)
        XCTAssertEqual(eng.mode, .visual(linewise: false))
        // Selection should be (0, 0) since buffer is empty
        let sel = emptyBuffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 0)
        // d should still exit to normal
        _ = eng.process("d", shift: false)
        XCTAssertEqual(eng.mode, .normal)
        XCTAssertEqual(emptyBuffer.text, "")
    }

    func testVisualModeSingleCharBuffer() {
        let singleBuffer = VimTextBufferMock(text: "a")
        let eng = VimEngine(buffer: singleBuffer)
        _ = eng.process("v", shift: false)
        let sel = singleBuffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 1)
        _ = eng.process("d", shift: false)
        XCTAssertEqual(singleBuffer.text, "")
        XCTAssertEqual(eng.mode, .normal)
    }

    func testVisualDeleteAllContent() {
        // Select everything: v at pos 0, G to end, d to delete
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("G", shift: true)
        // Should select entire buffer
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.location + sel.length, buffer.length)
        _ = key("d")
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVisualModeAnchorRemainsFixed() {
        // v at pos 5, l extends right, h returns, l again — anchor should always be 5
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("v") // anchor=5, cursor=5, sel=(5,1)

        _ = key("l") // cursor=6, sel=(5,2)
        XCTAssertEqual(buffer.selectedRange().location, 5)
        XCTAssertEqual(buffer.selectedRange().length, 2)

        _ = key("h") // cursor=5, sel=(5,1) — back to anchor
        XCTAssertEqual(buffer.selectedRange().location, 5)
        XCTAssertEqual(buffer.selectedRange().length, 1)

        _ = key("l") // cursor=6 again
        XCTAssertEqual(buffer.selectedRange().location, 5)
        XCTAssertEqual(buffer.selectedRange().length, 2)
    }

    func testVisualModeSelectionDirection() {
        // Start at pos 5, extend right past anchor, then left past anchor
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("v") // anchor=5, cursor=5, sel=(5,1)

        // Extend right
        _ = key("l") // cursor=6, sel=(5,2)
        _ = key("l") // cursor=7, sel=(5,3)
        XCTAssertEqual(buffer.selectedRange().location, 5)
        XCTAssertEqual(buffer.selectedRange().length, 3)

        // Now go back left past anchor
        _ = key("h") // cursor=6, sel=(5,2)
        _ = key("h") // cursor=5, sel=(5,1)
        _ = key("h") // cursor=4, sel=(4,2) — now left of anchor
        XCTAssertEqual(buffer.selectedRange().location, 4)
        XCTAssertEqual(buffer.selectedRange().length, 2)

        // Continue left
        _ = key("h") // cursor=3, sel=(3,3)
        XCTAssertEqual(buffer.selectedRange().location, 3)
        XCTAssertEqual(buffer.selectedRange().length, 3)
    }

    // MARK: - Visual Mode Count Prefix

    func testVisualCountL() {
        // Visual mode does not implement count prefix. Digits are consumed as unknown keys.
        // So pressing "3" then "l" only executes l once.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("3")
        _ = key("l")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 2) // Only 1 l motion, not 3
    }

    func testVisualCountJ() {
        // Same: count prefix not handled in visual mode
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("2")
        _ = key("j")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        // Only 1 j motion: moves to line 1 col 0 = pos 12, inclusive = 13
        XCTAssertEqual(sel.length, 13)
    }

    // MARK: - Visual to Normal Mode Transitions

    func testVisualEscapeThenMotion() {
        // After escape from visual, motions should work in normal mode
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        escape()
        XCTAssertEqual(engine.mode, .normal)
        // Now l in normal mode should move cursor right
        _ = key("l")
        XCTAssertEqual(buffer.selectedRange().location, 1)
        XCTAssertEqual(buffer.selectedRange().length, 0)
    }

    func testVisualDeleteThenUndo() {
        // d in visual sets register and returns to normal
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("e") // Select "hello"
        _ = key("d")
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(buffer.text, " world\nsecond line\nthird line\n")
        // Verify register by pasting: cursor at 0, p inserts at pos 1
        _ = key("p")
        XCTAssertEqual(buffer.text, " helloworld\nsecond line\nthird line\n")
    }

    func testVisualYankThenPasteBefore() {
        // y in visual yanks, then P pastes before cursor
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("e") // Select "hello"
        _ = key("y")
        // Cursor at pos 0 after yank
        XCTAssertEqual(buffer.selectedRange().location, 0)
        // P pastes before cursor at pos 0
        _ = key("P", shift: true)
        XCTAssertEqual(buffer.text, "hellohello world\nsecond line\nthird line\n")
    }

    // MARK: - Mode Switching: v <-> V

    func testVThenShiftVSwitchesToLinewise() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
        _ = key("V", shift: true)
        XCTAssertEqual(engine.mode, .visual(linewise: true))
        // Linewise should select entire line
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 12) // "hello world\n"
    }

    func testShiftVThenVSwitchesToCharacterwise() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        _ = key("V", shift: true)
        XCTAssertEqual(engine.mode, .visual(linewise: true))
        _ = key("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    // MARK: - gg in Visual Mode

    func testVisualGGFromMiddleOfBuffer() {
        // At pos 28 (line 2), gg extends to pos 0
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        _ = key("v")
        keys("gg")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        // anchor=28, cursor=0, start=0, end=28, length=29
        XCTAssertEqual(sel.length, 29)
    }

    func testVisualGUnknownConsumed() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        let consumed = key("g")
        XCTAssertTrue(consumed)
        let consumed2 = key("z") // Unknown after g
        XCTAssertTrue(consumed2)
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    // MARK: - Visual Line Mode gg/G

    func testVisualLineGGExtendsToFirstLine() {
        buffer.setSelectedRange(NSRange(location: 28, length: 0)) // Line 2
        _ = key("V", shift: true)
        keys("gg")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, buffer.length) // All lines selected
    }

    func testVisualLineGExtendsToLastLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("V", shift: true)
        _ = key("G", shift: true)
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, buffer.length) // All lines selected
    }

    // MARK: - Visual Mode x (alias for d)

    func testVisualXDeletesSameAsD() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        _ = key("l")
        _ = key("x")
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(buffer.text, "llo world\nsecond line\nthird line\n")
    }

    // MARK: - Visual Line Mode Change

    func testVisualLineModeChangeDeletesAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("V", shift: true)
        _ = key("c")
        XCTAssertEqual(engine.mode, .insert)
    }

    // MARK: - Unknown Keys in Visual Mode

    func testUnknownKeyConsumedInVisualMode() {
        _ = key("v")
        let consumed = key("z")
        XCTAssertTrue(consumed)
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    // MARK: - Visual Delete Empty Selection

    func testVisualDeleteEmptySelectionStillExitsToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("v")
        // Force empty selection
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = key("d")
        XCTAssertEqual(engine.mode, .normal)
        // Buffer should be unchanged (nothing to delete)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    // MARK: - Forward then Backward (cursor crosses anchor)

    func testVLThenHReturnsToSingleChar() {
        // At pos 3: v selects "l" (3,1), l extends to "lo" (3,2), h returns to "l" (3,1)
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        _ = key("v")
        _ = key("l")
        let sel1 = buffer.selectedRange()
        XCTAssertEqual(sel1.location, 3)
        XCTAssertEqual(sel1.length, 2)
        _ = key("h")
        let sel2 = buffer.selectedRange()
        XCTAssertEqual(sel2.location, 3)
        XCTAssertEqual(sel2.length, 1)
    }

    func testVHThenLReturnsToSingleChar() {
        // At pos 3: v selects "l" (3,1), h extends backward to "ll" (2,2), l returns to "l" (3,1)
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        _ = key("v")
        _ = key("h")
        let sel1 = buffer.selectedRange()
        XCTAssertEqual(sel1.location, 2)
        XCTAssertEqual(sel1.length, 2)
        _ = key("l")
        let sel2 = buffer.selectedRange()
        XCTAssertEqual(sel2.location, 3)
        XCTAssertEqual(sel2.length, 1)
    }

    // MARK: - Visual at End of Line

    func testVisualModeAtEndOfLine() {
        // Cursor at last content char of line 0 (pos 10 = 'd')
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        _ = key("v")
        _ = key("l")
        let sel = buffer.selectedRange()
        // l in visual: min(buffer.length, 10+1) = 11
        // anchor=10, cursor=11, start=10, end=11, length = 11-10 + (11 < 35 ? 1 : 0) = 2
        XCTAssertEqual(sel.location, 10)
        XCTAssertEqual(sel.length, 2) // "d\n"
    }
}

// swiftlint:enable file_length type_body_length
