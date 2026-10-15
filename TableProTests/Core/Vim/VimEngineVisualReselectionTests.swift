//
//  VimEngineVisualReselectionTests.swift
//  TableProTests
//
//  Spec for gv (reselect last visual) and the '< / '> jump marks that bracket
//  the most recent visual selection.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineVisualReselectionTests {
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

    // MARK: - gv: Reselect Last Visual

    @Test
    func gVReselectsLastCharacterwiseVisual() {
        // Make a selection in visual mode and exit.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("lll")
        let originalSel = buffer.selectedRange()
        escape()
        #expect(engine.mode == .normal)
        // Move cursor somewhere else.
        keys("0")
        keys("j")
        // gv should restore the original visual selection.
        keys("gv")
        #expect(engine.mode == .visual(linewise: false),
            "gv should re-enter visual mode")
        #expect(buffer.selectedRange().location == originalSel.location,
            "gv should restore the original selection location")
        #expect(buffer.selectedRange().length == originalSel.length,
            "gv should restore the original selection length")
    }

    @Test
    func gVReselectsLastLinewiseVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("j")
        let originalSel = buffer.selectedRange()
        escape()
        keys("G")
        keys("gv")
        #expect(engine.mode == .visual(linewise: true),
            "gv after V should re-enter linewise visual mode")
        #expect(buffer.selectedRange().location == originalSel.location)
        #expect(buffer.selectedRange().length == originalSel.length)
    }

    @Test
    func gVAfterDeleteOperationStillReselectable() {
        // Even after running an operator on the selection, gv should reselect.
        // The selection bounds may shift to track the edit, but the visual region
        // (now containing whatever replaced the deleted text) should be reselectable.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlll")
        keys("d")
        #expect(engine.mode == .normal)
        keys("gv")
        #expect(engine.mode == .visual(linewise: false),
            "gv should still enter visual mode after a delete operation")
    }

    // MARK: - '< and '> Jump Marks

    @Test
    func jumpToLastSelectionStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("lll")
        let start = buffer.selectedRange().location
        escape()
        keys("G")
        keys("`<")
        #expect(buffer.selectedRange().location == start,
            "`< should jump to the start of the last visual selection")
    }

    @Test
    func jumpToLastSelectionEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("lll")
        let sel = buffer.selectedRange()
        let inclusiveEnd = sel.location + max(0, sel.length - 1)
        escape()
        keys("G")
        keys("`>")
        #expect(buffer.selectedRange().location == inclusiveEnd,
            "`> should jump to the inclusive-end of the last visual selection")
    }

    // MARK: - gv Without Prior Selection

    @Test
    func gVWithNoPriorSelectionIsNoOp() {
        // Fresh engine, no previous visual selection.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("gv")
        #expect(engine.mode == .normal,
            "gv with no prior selection should remain in normal mode (no-op)")
    }
}
