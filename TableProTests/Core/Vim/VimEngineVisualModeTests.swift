//
//  VimEngineVisualModeTests.swift
//  TableProTests
//
//  Specification tests for Visual mode (v) and Visual Line mode (V):
//  entry/exit, motions, operators (d/y/c/x/J/~), and the o swap-anchor command.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineVisualModeTests {
    // Standard test buffer:
    // Line 0: "hello world\n"   offsets 0..11   (length 12)
    // Line 1: "second line\n"   offsets 12..23  (length 12)
    // Line 2: "third line\n"    offsets 24..34  (length 11)
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

    private var sel: NSRange { buffer.selectedRange() }

    // MARK: - v: Enter Characterwise Visual

    @Test
    func vEntersVisualMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        #expect(engine.mode == .visual(linewise: false))
    }

    @Test
    func vSelectsSingleCharInitially() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("v")
        #expect(sel.location == 3)
        #expect(sel.length == 1, "Initial v selection should cover one character")
        #expect(buffer.string(in: sel) == "l")
    }

    @Test
    func vOnEmptyBuffer() {
        buffer = VimTextBufferMock(text: "")
        engine = VimEngine(buffer: buffer)
        keys("v")
        #expect(engine.mode == .visual(linewise: false))
        #expect(sel.length == 0, "Empty buffer should yield zero-length selection on v")
    }

    // MARK: - V: Enter Linewise Visual

    @Test
    func capitalVEntersLinewiseVisual() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        #expect(engine.mode == .visual(linewise: true))
    }

    @Test
    func capitalVSelectsEntireLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        #expect(sel.location == 0)
        #expect(sel.length == 12, "V should select the entire line 0 ('hello world\\n')")
    }

    // MARK: - Toggle: v <-> V <-> Normal

    @Test
    func vTogglesOffToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vv")
        #expect(engine.mode == .normal)
        #expect(sel.length == 0)
    }

    @Test
    func capitalVTogglesOffToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        key("V", shift: true)
        #expect(engine.mode == .normal)
    }

    @Test
    func vThenCapitalVSwitchesToLinewise() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("v")
        key("V", shift: true)
        #expect(engine.mode == .visual(linewise: true))
    }

    @Test
    func capitalVThenVSwitchesToCharacterwise() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        keys("v")
        #expect(engine.mode == .visual(linewise: false))
    }

    // MARK: - Escape Exits Visual

    @Test
    func escapeExitsToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        escape()
        #expect(engine.mode == .normal)
        #expect(sel.length == 0)
    }

    // MARK: - Motions Extend Selection

    @Test
    func lExtendsRightInclusive() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vl")
        #expect(sel.location == 0)
        #expect(sel.length == 2)
        #expect(buffer.string(in: sel) == "he")
    }

    @Test
    func hExtendsLeftInclusive() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("vh")
        #expect(sel.location == 4)
        #expect(sel.length == 2)
    }

    @Test
    func wExtendsByWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vw")
        #expect(sel.location == 0)
        #expect(buffer.string(in: sel) == "hello w")
    }

    @Test
    func eExtendsToWordEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        #expect(sel.location == 0)
        #expect(sel.length == 5)
        #expect(buffer.string(in: sel) == "hello")
    }

    @Test
    func bExtendsBackwardByWord() {
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("vb")
        #expect(sel.location == 6)
        #expect(buffer.string(in: sel) == "wor")
    }

    @Test
    func dollarExtendsToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v$")
        #expect(sel.location == 0)
        #expect(sel.length == 12, "v$ should extend through the line including newline")
    }

    @Test
    func zeroExtendsToLineStart() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("v0")
        #expect(sel.location == 0)
        #expect(sel.length == 6, "v0 should extend selection to the start of line")
    }

    @Test
    func caretExtendsToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("v^")
        #expect(sel.location == 3)
        #expect(sel.length == 5)
    }

    // MARK: - Multi-line Motions

    @Test
    func jExtendsToNextLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vj")
        #expect(sel.location == 0)
        #expect(buffer.string(in: sel) == "hello world\ns")
    }

    @Test
    func kExtendsToPreviousLine() {
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("vk")
        #expect(sel.location == 3)
        #expect(sel.length == 13)
    }

    @Test
    func gGExtendsToBufferStart() {
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("vgg")
        #expect(sel.location == 0)
        #expect(sel.length == 16)
    }

    @Test
    func capitalGExtendsToBufferEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        key("G", shift: true)
        #expect(sel.location == 0)
        #expect(sel.location + sel.length == buffer.length)
    }

    // MARK: - o: Swap Anchor and Cursor

    @Test
    func oSwapsAnchorAndCursor() {
        // v at 5 selects ' ' (5,1), l → (5,2), l → (5,3) — cursor at 7.
        // o swaps anchor/cursor — now anchor=7, cursor=5. Selection still (5,3).
        // Then h should shrink from the LEFT (cursor) end.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("vll")
        #expect(sel.location == 5)
        #expect(sel.length == 3)
        keys("o")
        // After o, h moves the LEFT side outward (extend left).
        keys("h")
        #expect(sel.location == 4, "After o, h should extend from the new cursor (left side)")
    }

    @Test
    func oInLinewise() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        key("V", shift: true)
        keys("j")
        // Selection covers lines 1-2.
        keys("o")
        // Now extending with k should grow upward from the new cursor.
        keys("k")
        #expect(sel.location == 0, "After o in linewise mode, k should extend upward")
    }

    // MARK: - Anchor Stays Fixed

    @Test
    func anchorStaysFixedAcrossExtendingAndShrinking() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("v")
        keys("lll") // extend right
        #expect(sel.location == 5)
        #expect(sel.length == 4)
        keys("hhh") // shrink back
        #expect(sel.location == 5)
        #expect(sel.length == 1)
    }

    @Test
    func cursorCanCrossAnchorLeftward() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("vhhh")
        // anchor=5, cursor=2 → selection (2,4)
        #expect(sel.location == 2)
        #expect(sel.length == 4)
    }

    // MARK: - Operators in Visual Mode

    @Test
    func dDeletesSelection() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlld")
        #expect(buffer.text == "lo world\nsecond line\nthird line\n")
        #expect(engine.mode == .normal)
    }

    @Test
    func xIsAliasForDInVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vllx")
        #expect(buffer.text == "lo world\nsecond line\nthird line\n")
        #expect(engine.mode == .normal)
    }

    @Test
    func yYanksSelectionWithoutModifyingBuffer() {
        let original = buffer.text
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vey")
        #expect(buffer.text == original)
        #expect(engine.mode == .normal)
    }

    @Test
    func yReturnsCursorToAnchor() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vey")
        #expect(sel.location == 0, "Yank should leave cursor at the start of the yanked region")
    }

    @Test
    func cChangesSelectionAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlc")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "llo world\nsecond line\nthird line\n")
    }

    @Test
    func deleteThenPasteRoundTrip() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlld")
        // Selection was "hel" — should be in register.
        key("P", shift: true)
        #expect(buffer.text == "hello world\nsecond line\nthird line\n",
            "Deleted selection should round-trip through P")
    }

    // MARK: - Linewise Operations

    @Test
    func linewiseDDeletesWholeLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("V", shift: true)
        keys("d")
        #expect(buffer.text == "second line\nthird line\n")
    }

    @Test
    func linewiseDMultipleLines() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("jd")
        #expect(buffer.text == "third line\n")
    }

    @Test
    func linewiseYThenP() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("yp")
        #expect(buffer.text == "hello world\nhello world\nsecond line\nthird line\n")
    }

    @Test
    func linewiseCDeletesContentEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("c")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "\nsecond line\nthird line\n",
            "Linewise change should delete content but keep one newline")
    }

    // MARK: - ~ Toggle Case in Visual

    @Test
    func tildeTogglesCaseInVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        keys("~")
        #expect(buffer.text == "HELLO world\nsecond line\nthird line\n",
            "~ in visual should toggle case of the selection and exit to normal")
        #expect(engine.mode == .normal)
    }

    @Test
    func guLowercasesSelection() {
        buffer = VimTextBufferMock(text: "Hello World\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v$")
        keys("u")
        #expect(buffer.text == "hello world\n",
            "Selecting and pressing u in visual should lowercase the selection")
    }

    @Test
    func gUUppercaseSelection() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("e")
        key("U", shift: true)
        #expect(buffer.text == "HELLO world\nsecond line\nthird line\n",
            "Selecting and pressing U in visual should uppercase the selection")
    }

    // MARK: - r in Visual

    @Test
    func rReplacesSelectionWithSingleChar() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        keys("rX")
        #expect(buffer.text == "XXXXX world\nsecond line\nthird line\n",
            "r in visual should replace every char in selection with the given char")
        #expect(engine.mode == .normal)
    }

    // MARK: - Edge Cases

    @Test
    func visualAtBufferStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vh")
        #expect(sel.location == 0)
        #expect(sel.length == 1)
    }

    @Test
    func visualAtBufferEnd() {
        buffer.setSelectedRange(NSRange(location: 34, length: 0))
        keys("v")
        #expect(sel.location == 34)
        #expect(sel.length == 1)
        keys("l")
        #expect(sel.location == 34, "l at buffer end should not extend past length")
    }

    @Test
    func visualDeleteAllContent() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        key("G", shift: true)
        keys("d")
        #expect(buffer.text == "")
        #expect(engine.mode == .normal)
    }

    // MARK: - Unknown Keys

    @Test
    func unknownKeyConsumedInVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        let consumed = engine.process("z", shift: false)
        #expect(consumed)
        #expect(engine.mode == .visual(linewise: false),
            "Unknown keys in visual must be consumed but not exit visual mode")
    }

    // MARK: - Insert Mode From Visual

    @Test
    func iInVisualBlockShouldInsertAtSelectionStart() {
        // This is more meaningful in block visual; in regular visual, I just enters insert
        // at the cursor position. We assert the engine does not crash and exits visual.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ve")
        key("I", shift: true)
        #expect(engine.mode == .insert)
    }

    // MARK: - Mode Display

    @Test
    func visualDisplayLabel() {
        keys("v")
        #expect(engine.mode.displayLabel == "VISUAL")
    }

    @Test
    func visualLineDisplayLabel() {
        key("V", shift: true)
        #expect(engine.mode.displayLabel == "VISUAL LINE")
    }
}

// swiftlint:enable file_length type_body_length
