//
//  VimEnginePasteTests.swift
//  TableProTests
//
//  Specification tests for p / P paste behavior — characterwise vs linewise,
//  count repetition, and cursor positioning rules.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEnginePasteTests: XCTestCase {
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

    // MARK: - p: Paste After (Characterwise)

    func testPPastesCharacterwiseAfterCursor() {
        // yw yanks "hello ", p pastes it after the cursor (i.e., starting at pos+1).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ywp")
        XCTAssertEqual(buffer.text, "hhello ello world\nsecond line\nthird line\n")
    }

    func testPCursorLandsOnLastPastedChar() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw") // register: "hello "
        keys("p")
        // Inserted at offset 1, length 6. Cursor on last pasted char = offset 6.
        XCTAssertEqual(pos, 6, "After characterwise p, cursor sits on the last pasted character")
    }

    func testPAtEndOfLineInsertsBeforeNewline() {
        // Delete a char to load register, then paste at end of line.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // register: "h"
        // Now at offset 0 ('e'), move to end of line first
        keys("$")
        keys("p")
        XCTAssertEqual(buffer.text, "ello worldh\nsecond line\nthird line\n",
            "Characterwise p at end of line should insert just before the newline")
    }

    // MARK: - P: Paste Before (Characterwise)

    func testCapitalPPastesCharacterwiseBeforeCursor() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0)) // 'w' in 'world'
        keys("x") // delete 'w', register: "w"
        key("P", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "P should restore deleted char before cursor")
    }

    func testCapitalPCursorLandsOnLastPastedChar() {
        // Yank "hello", move to start of line 1, P should paste before and land on 'o'.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ye") // yank "hello"
        keys("j0")
        key("P", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nhellosecond line\nthird line\n")
        XCTAssertEqual(pos, 16, "After characterwise P, cursor sits on the last pasted char")
    }

    // MARK: - p: Paste After (Linewise)

    func testLinewisePPastesAsNewLineBelow() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nthird line\n")
    }

    func testLinewisePCursorLandsOnFirstPastedLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        XCTAssertEqual(pos, 12, "Cursor should land at start of the pasted line")
    }

    func testLinewisePOnLastLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "one\ntwo")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        XCTAssertEqual(buffer.text, "one\none\ntwo")
    }

    // MARK: - P: Paste Before (Linewise)

    func testLinewiseCapitalPPastesAsNewLineAbove() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0)) // start of line 1
        keys("yy")
        key("P", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nsecond line\nthird line\n")
    }

    func testLinewiseCapitalPCursorLandsOnFirstPastedLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("yy")
        key("P", shift: true)
        XCTAssertEqual(pos, 12, "Cursor should land at start of the pasted line")
    }

    // MARK: - Paste with Count

    func testPasteWithCountRepeatsPaste() {
        // yw to yank "hello ", 3p to paste 3 times.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw")
        keys("3p")
        XCTAssertEqual(buffer.text, "hhello hello hello ello world\nsecond line\nthird line\n",
            "3p should paste the register 3 times")
    }

    func testLinewisePasteWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        keys("2p")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nhello world\nsecond line\nthird line\n",
            "2p with linewise register should insert two copies after current line")
    }

    // MARK: - Empty Register

    func testPasteWithEmptyRegisterIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("p")
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "Pasting an empty register should not modify the buffer")
    }

    // MARK: - Cross-Operator Register Use

    func testYankPasteThenDeletePasteOverwritesRegister() {
        // yank line, paste it, then delete a line — the deleted line takes over as paste source.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        keys("j")
        keys("dd")
        XCTAssertEqual(buffer.text, "hello world\nthird line\n",
            "dd should delete the second line")
        keys("p")
        XCTAssertEqual(buffer.text, "hello world\nthird line\nsecond line\n",
            "After dd overwrites register, p should paste the deleted second line")
    }

    func testXThenPasteRoundTrips() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // delete 'h'
        XCTAssertEqual(buffer.text, "ello world\nsecond line\nthird line\n")
        key("P", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "x stores into the register; P should restore")
    }

    // MARK: - Visual Selection Paste Replaces Selection

    func testPasteInVisualReplacesSelectionWithRegister() {
        // yw to yank "hello ", then v3l to select "wor" in "world", p to replace.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw") // register: "hello "
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("v")
        keys("ll")
        keys("p")
        XCTAssertEqual(buffer.text, "hello hello ld\nsecond line\nthird line\n",
            "Paste over a visual selection should replace the selection with the register")
        XCTAssertEqual(engine.mode, .normal)
    }
}
