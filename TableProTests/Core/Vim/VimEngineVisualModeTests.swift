//
//  VimEngineVisualModeTests.swift
//  TableProTests
//
//  Specification tests for Visual mode (v) and Visual Line mode (V):
//  entry/exit, motions, operators (d/y/c/x/J/~), and the o swap-anchor command.
//

import XCTest
import TableProPluginKit
@testable import TablePro

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineVisualModeTests: XCTestCase {
    // Standard test buffer:
    // Line 0: "hello world\n"   offsets 0..11   (length 12)
    // Line 1: "second line\n"   offsets 12..23  (length 12)
    // Line 2: "third line\n"    offsets 24..34  (length 11)
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

    private func escape() { _ = engine.process("\u{1B}", shift: false) }

    private var sel: NSRange { buffer.selectedRange() }

    // MARK: - v: Enter Characterwise Visual

    func testVEntersVisualMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    func testVSelectsSingleCharInitially() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("v")
        XCTAssertEqual(sel.location, 3)
        XCTAssertEqual(sel.length, 1, "Initial v selection should cover one character")
        XCTAssertEqual(buffer.string(in: sel), "l")
    }

    func testVOnEmptyBuffer() {
        buffer = VimTextBufferMock(text: "")
        engine = VimEngine(buffer: buffer)
        keys("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
        XCTAssertEqual(sel.length, 0, "Empty buffer should yield zero-length selection on v")
    }

    // MARK: - V: Enter Linewise Visual

    func testCapitalVEntersLinewiseVisual() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        XCTAssertEqual(engine.mode, .visual(linewise: true))
    }

    func testCapitalVSelectsEntireLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 12, "V should select the entire line 0 ('hello world\\n')")
    }

    // MARK: - Toggle: v <-> V <-> Normal

    func testVTogglesOffToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vv")
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(sel.length, 0)
    }

    func testCapitalVTogglesOffToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        key("V", shift: true)
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVThenCapitalVSwitchesToLinewise() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("v")
        key("V", shift: true)
        XCTAssertEqual(engine.mode, .visual(linewise: true))
    }

    func testCapitalVThenVSwitchesToCharacterwise() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        keys("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    // MARK: - Escape Exits Visual

    func testEscapeExitsToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        escape()
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(sel.length, 0)
    }

    // MARK: - Motions Extend Selection

    func testLExtendsRightInclusive() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vl")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 2)
        XCTAssertEqual(buffer.string(in: sel), "he")
    }

    func testHExtendsLeftInclusive() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("vh")
        XCTAssertEqual(sel.location, 4)
        XCTAssertEqual(sel.length, 2)
    }

    func testWExtendsByWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vw")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(buffer.string(in: sel), "hello w")
    }

    func testEExtendsToWordEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 5)
        XCTAssertEqual(buffer.string(in: sel), "hello")
    }

    func testBExtendsBackwardByWord() {
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("vb")
        XCTAssertEqual(sel.location, 6)
        XCTAssertEqual(buffer.string(in: sel), "wor")
    }

    func testDollarExtendsToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v$")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 12, "v$ should extend through the line including newline")
    }

    func testZeroExtendsToLineStart() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("v0")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 6, "v0 should extend selection to the start of line")
    }

    func testCaretExtendsToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("v^")
        XCTAssertEqual(sel.location, 3)
        XCTAssertEqual(sel.length, 5)
    }

    // MARK: - Multi-line Motions

    func testJExtendsToNextLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vj")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(buffer.string(in: sel), "hello world\ns")
    }

    func testKExtendsToPreviousLine() {
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("vk")
        XCTAssertEqual(sel.location, 3)
        XCTAssertEqual(sel.length, 13)
    }

    func testGGExtendsToBufferStart() {
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("vgg")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 16)
    }

    func testCapitalGExtendsToBufferEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        key("G", shift: true)
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.location + sel.length, buffer.length)
    }

    // MARK: - o: Swap Anchor and Cursor

    func testOSwapsAnchorAndCursor() {
        // v at 5 selects ' ' (5,1), l → (5,2), l → (5,3) — cursor at 7.
        // o swaps anchor/cursor — now anchor=7, cursor=5. Selection still (5,3).
        // Then h should shrink from the LEFT (cursor) end.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("vll")
        XCTAssertEqual(sel.location, 5)
        XCTAssertEqual(sel.length, 3)
        keys("o")
        // After o, h moves the LEFT side outward (extend left).
        keys("h")
        XCTAssertEqual(sel.location, 4, "After o, h should extend from the new cursor (left side)")
    }

    func testOInLinewise() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        key("V", shift: true)
        keys("j")
        // Selection covers lines 1-2.
        keys("o")
        // Now extending with k should grow upward from the new cursor.
        keys("k")
        XCTAssertEqual(sel.location, 0, "After o in linewise mode, k should extend upward")
    }

    // MARK: - Anchor Stays Fixed

    func testAnchorStaysFixedAcrossExtendingAndShrinking() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("v")
        keys("lll") // extend right
        XCTAssertEqual(sel.location, 5)
        XCTAssertEqual(sel.length, 4)
        keys("hhh") // shrink back
        XCTAssertEqual(sel.location, 5)
        XCTAssertEqual(sel.length, 1)
    }

    func testCursorCanCrossAnchorLeftward() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("vhhh")
        // anchor=5, cursor=2 → selection (2,4)
        XCTAssertEqual(sel.location, 2)
        XCTAssertEqual(sel.length, 4)
    }

    // MARK: - Operators in Visual Mode

    func testDDeletesSelection() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlld")
        XCTAssertEqual(buffer.text, "lo world\nsecond line\nthird line\n")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testXIsAliasForDInVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vllx")
        XCTAssertEqual(buffer.text, "lo world\nsecond line\nthird line\n")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testYYanksSelectionWithoutModifyingBuffer() {
        let original = buffer.text
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vey")
        XCTAssertEqual(buffer.text, original)
        XCTAssertEqual(engine.mode, .normal)
    }

    func testYReturnsCursorToAnchor() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vey")
        XCTAssertEqual(sel.location, 0, "Yank should leave cursor at the start of the yanked region")
    }

    func testCChangesSelectionAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlc")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "llo world\nsecond line\nthird line\n")
    }

    func testDeleteThenPasteRoundTrip() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlld")
        // Selection was "hel" — should be in register.
        key("P", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "Deleted selection should round-trip through P")
    }

    // MARK: - Linewise Operations

    func testLinewiseDDeletesWholeLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        keys("d")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
    }

    func testLinewiseDMultipleLines() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("jd")
        XCTAssertEqual(buffer.text, "third line\n")
    }

    func testLinewiseYThenP() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("yp")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nthird line\n")
    }

    func testLinewiseCDeletesContentEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("c")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "\nsecond line\nthird line\n",
            "Linewise change should delete content but keep one newline")
    }

    // MARK: - ~ Toggle Case in Visual

    func testTildeTogglesCaseInVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        keys("~")
        XCTAssertEqual(buffer.text, "HELLO world\nsecond line\nthird line\n",
            "~ in visual should toggle case of the selection and exit to normal")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testGuLowercasesSelection() {
        buffer = VimTextBufferMock(text: "Hello World\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v$")
        keys("u")
        XCTAssertEqual(buffer.text, "hello world\n",
            "Selecting and pressing u in visual should lowercase the selection")
    }

    func testGUUppercaseSelection() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("e")
        key("U", shift: true)
        XCTAssertEqual(buffer.text, "HELLO world\nsecond line\nthird line\n",
            "Selecting and pressing U in visual should uppercase the selection")
    }

    // MARK: - r in Visual

    func testRReplacesSelectionWithSingleChar() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        keys("rX")
        XCTAssertEqual(buffer.text, "XXXXX world\nsecond line\nthird line\n",
            "r in visual should replace every char in selection with the given char")
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - Edge Cases

    func testVisualAtBufferStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vh")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, 1)
    }

    func testVisualAtBufferEnd() {
        buffer.setSelectedRange(NSRange(location: 34, length: 0))
        keys("v")
        XCTAssertEqual(sel.location, 34)
        XCTAssertEqual(sel.length, 1)
        keys("l")
        XCTAssertEqual(sel.location, 34, "l at buffer end should not extend past length")
    }

    func testVisualDeleteAllContent() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        key("G", shift: true)
        keys("d")
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - Unknown Keys

    func testUnknownKeyConsumedInVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        let consumed = engine.process("z", shift: false)
        XCTAssertTrue(consumed)
        XCTAssertEqual(engine.mode, .visual(linewise: false),
            "Unknown keys in visual must be consumed but not exit visual mode")
    }

    // MARK: - Insert Mode From Visual

    func testIInVisualBlockShouldInsertAtSelectionStart() {
        // This is more meaningful in block visual; in regular visual, I just enters insert
        // at the cursor position. We assert the engine does not crash and exits visual.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        key("I", shift: true)
        XCTAssertEqual(engine.mode, .insert)
    }

    // MARK: - Mode Display

    func testVisualDisplayLabel() {
        keys("v")
        XCTAssertEqual(engine.mode.displayLabel, "VISUAL")
    }

    func testVisualLineDisplayLabel() {
        key("V", shift: true)
        XCTAssertEqual(engine.mode.displayLabel, "VISUAL LINE")
    }
}

// swiftlint:enable file_length type_body_length
