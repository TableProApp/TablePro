//
//  VimEngineVisualReselectionTests.swift
//  TableProTests
//
//  Spec for gv (reselect last visual) and the '< / '> jump marks that bracket
//  the most recent visual selection.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineVisualReselectionTests: XCTestCase {
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

    // MARK: - gv: Reselect Last Visual

    func testGVReselectsLastCharacterwiseVisual() {
        // Make a selection in visual mode and exit.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("lll")
        let originalSel = buffer.selectedRange()
        escape()
        XCTAssertEqual(engine.mode, .normal)
        // Move cursor somewhere else.
        keys("0")
        keys("j")
        // gv should restore the original visual selection.
        keys("gv")
        XCTAssertEqual(engine.mode, .visual(linewise: false),
            "gv should re-enter visual mode")
        XCTAssertEqual(buffer.selectedRange().location, originalSel.location,
            "gv should restore the original selection location")
        XCTAssertEqual(buffer.selectedRange().length, originalSel.length,
            "gv should restore the original selection length")
    }

    func testGVReselectsLastLinewiseVisual() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("V", shift: true)
        keys("j")
        let originalSel = buffer.selectedRange()
        escape()
        keys("G")
        keys("gv")
        XCTAssertEqual(engine.mode, .visual(linewise: true),
            "gv after V should re-enter linewise visual mode")
        XCTAssertEqual(buffer.selectedRange().location, originalSel.location)
        XCTAssertEqual(buffer.selectedRange().length, originalSel.length)
    }

    func testGVAfterDeleteOperationStillReselectable() {
        // Even after running an operator on the selection, gv should reselect.
        // The selection bounds may shift to track the edit, but the visual region
        // (now containing whatever replaced the deleted text) should be reselectable.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("vlll")
        keys("d")
        XCTAssertEqual(engine.mode, .normal)
        keys("gv")
        XCTAssertEqual(engine.mode, .visual(linewise: false),
            "gv should still enter visual mode after a delete operation")
    }

    // MARK: - '< and '> Jump Marks

    func testJumpToLastSelectionStart() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("lll")
        let start = buffer.selectedRange().location
        escape()
        keys("G")
        keys("`<")
        XCTAssertEqual(buffer.selectedRange().location, start,
            "`< should jump to the start of the last visual selection")
    }

    func testJumpToLastSelectionEnd() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("lll")
        let sel = buffer.selectedRange()
        let inclusiveEnd = sel.location + max(0, sel.length - 1)
        escape()
        keys("G")
        keys("`>")
        XCTAssertEqual(buffer.selectedRange().location, inclusiveEnd,
            "`> should jump to the inclusive-end of the last visual selection")
    }

    // MARK: - gv Without Prior Selection

    func testGVWithNoPriorSelectionIsNoOp() {
        // Fresh engine, no previous visual selection.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("gv")
        XCTAssertEqual(engine.mode, .normal,
            "gv with no prior selection should remain in normal mode (no-op)")
    }
}
