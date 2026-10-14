//
//  VimEnginePasteTests.swift
//  TableProTests
//
//  Specification tests for p / P paste behavior — characterwise vs linewise,
//  count repetition, and cursor positioning rules.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEnginePasteTests {
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

    // MARK: - p: Paste After (Characterwise)

    @Test
    func pPastesCharacterwiseAfterCursor() {
        // yw yanks "hello ", p pastes it after the cursor (i.e., starting at pos+1).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ywp")
        #expect(buffer.text == "hhello ello world\nsecond line\nthird line\n")
    }

    @Test
    func pCursorLandsOnLastPastedChar() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw") // register: "hello "
        keys("p")
        // Inserted at offset 1, length 6. Cursor on last pasted char = offset 6.
        #expect(pos == 6, "After characterwise p, cursor sits on the last pasted character")
    }

    @Test
    func pAtEndOfLineInsertsBeforeNewline() {
        // Delete a char to load register, then paste at end of line.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // register: "h"
        // Now at offset 0 ('e'), move to end of line first
        keys("$")
        keys("p")
        #expect(buffer.text == "ello worldh\nsecond line\nthird line\n",
            "Characterwise p at end of line should insert just before the newline")
    }

    // MARK: - P: Paste Before (Characterwise)

    @Test
    func capitalPPastesCharacterwiseBeforeCursor() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0)) // 'w' in 'world'
        keys("x") // delete 'w', register: "w"
        key("P", shift: true)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "P should restore deleted char before cursor")
    }

    @Test
    func capitalPCursorLandsOnLastPastedChar() {
        // Yank "hello", move to start of line 1, P should paste before and land on 'o'.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ye") // yank "hello"
        keys("j0")
        key("P", shift: true)
        #expect(buffer.text == "hello world\nhellosecond line\nthird line\n")
        #expect(pos == 16, "After characterwise P, cursor sits on the last pasted char")
    }

    // MARK: - p: Paste After (Linewise)

    @Test
    func linewisePPastesAsNewLineBelow() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        #expect(buffer.text == "hello world\nhello world\nsecond line\nthird line\n")
    }

    @Test
    func linewisePCursorLandsOnFirstPastedLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        #expect(pos == 12, "Cursor should land at start of the pasted line")
    }

    @Test
    func linewisePOnLastLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "one\ntwo")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        #expect(buffer.text == "one\none\ntwo")
    }

    // MARK: - P: Paste Before (Linewise)

    @Test
    func linewiseCapitalPPastesAsNewLineAbove() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0)) // start of line 1
        keys("yy")
        key("P", shift: true)
        #expect(buffer.text == "hello world\nsecond line\nsecond line\nthird line\n")
    }

    @Test
    func linewiseCapitalPCursorLandsOnFirstPastedLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("yy")
        key("P", shift: true)
        #expect(pos == 12, "Cursor should land at start of the pasted line")
    }

    // MARK: - Paste with Count

    @Test
    func pasteWithCountRepeatsPaste() {
        // yw to yank "hello ", 3p to paste 3 times.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw")
        keys("3p")
        #expect(buffer.text == "hhello hello hello ello world\nsecond line\nthird line\n",
            "3p should paste the register 3 times")
    }

    @Test
    func linewisePasteWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        keys("2p")
        #expect(buffer.text == "hello world\nhello world\nhello world\nsecond line\nthird line\n",
            "2p with linewise register should insert two copies after current line")
    }

    // MARK: - Empty Register

    @Test
    func pasteWithEmptyRegisterIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("p")
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "Pasting an empty register should not modify the buffer")
    }

    // MARK: - Cross-Operator Register Use

    @Test
    func yankPasteThenDeletePasteOverwritesRegister() {
        // yank line, paste it, then delete a line — the deleted line takes over as paste source.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        keys("j")
        keys("dd")
        #expect(buffer.text == "hello world\nthird line\n",
            "dd should delete the second line")
        keys("p")
        #expect(buffer.text == "hello world\nthird line\nsecond line\n",
            "After dd overwrites register, p should paste the deleted second line")
    }

    @Test
    func xThenPasteRoundTrips() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // delete 'h'
        #expect(buffer.text == "ello world\nsecond line\nthird line\n")
        key("P", shift: true)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "x stores into the register; P should restore")
    }

    // MARK: - Visual Selection Paste Replaces Selection

    @Test
    func pasteInVisualReplacesSelectionWithRegister() {
        // yw to yank "hello ", then v3l to select "wor" in "world", p to replace.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw") // register: "hello "
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("v")
        keys("ll")
        keys("p")
        #expect(buffer.text == "hello hello ld\nsecond line\nthird line\n",
            "Paste over a visual selection should replace the selection with the register")
        #expect(engine.mode == .normal)
    }
}
