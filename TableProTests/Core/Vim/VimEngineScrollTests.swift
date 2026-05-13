//
//  VimEngineScrollTests.swift
//  TableProTests
//
//  Spec for vim's scroll commands and cursor-relative-to-viewport commands.
//  These rely on the VimTextBuffer.visibleLineRange contract; the mock returns
//  the whole buffer so behaviour is well-defined for unit tests.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineScrollTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        // 30-line buffer so we can exercise half-page / full-page motions.
        var lines: [String] = []
        for i in 0..<30 { lines.append("line\(i)") }
        buffer = VimTextBufferMock(text: lines.joined(separator: "\n") + "\n")
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

    private func ctrl(_ char: Character) -> Bool {
        // Ctrl is handled at the interceptor layer, but for these engine-level tests
        // we use the equivalent ASCII control code so the engine path can interpret it.
        let raw = char.asciiValue.map { UInt8($0 & 0x1F) } ?? 0
        let scalar = UnicodeScalar(raw)
        return engine.process(Character(scalar), shift: false)
    }

    private var line: Int {
        buffer.lineAndColumn(forOffset: buffer.selectedRange().location).line
    }

    // MARK: - Ctrl+D / Ctrl+U: Half-Page Scroll

    func testCtrlDScrollsHalfPageDown() {
        // Mock visibleLineRange returns (0, 29). Half is 15. Ctrl+D moves cursor down ~half.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = ctrl("d")
        XCTAssertEqual(line, 15, "Ctrl+D should move the cursor down by half the visible range")
    }

    func testCtrlUScrollsHalfPageUp() {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: 25, column: 0), length: 0))
        _ = ctrl("u")
        XCTAssertEqual(line, 10, "Ctrl+U should move the cursor up by half the visible range")
    }

    // MARK: - Ctrl+F / Ctrl+B: Full-Page Scroll

    func testCtrlFScrollsFullPageDown() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        _ = ctrl("f")
        XCTAssertEqual(line, 29, "Ctrl+F should move down by the full visible range (clamped at last line)")
    }

    func testCtrlBScrollsFullPageUp() {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: 29, column: 0), length: 0))
        _ = ctrl("b")
        XCTAssertEqual(line, 0, "Ctrl+B should move up by the full visible range (clamped at first line)")
    }

    // MARK: - Ctrl+E / Ctrl+Y: Scroll Lines Without Moving Cursor

    func testCtrlEScrollsViewportDown() {
        // Engine cannot directly scroll a viewport via the mock — but it should
        // advance the cursor if the viewport carries it (vim's "stick to visible").
        // For the mock (whole buffer visible), this is effectively a no-op.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        let consumed = ctrl("e")
        XCTAssertTrue(consumed, "Ctrl+E should be consumed by the engine even when nothing scrolls")
    }

    func testCtrlYScrollsViewportUp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        let consumed = ctrl("y")
        XCTAssertTrue(consumed)
    }

    // MARK: - z Commands: Position Current Line in Viewport

    func testZtPlacesCursorLineAtTop() {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: 10, column: 0), length: 0))
        keys("zt")
        // Cursor itself should not move; only the viewport is adjusted.
        XCTAssertEqual(line, 10, "zt should not change the cursor's line")
    }

    func testZzCentersCursorLine() {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: 5, column: 0), length: 0))
        keys("zz")
        XCTAssertEqual(line, 5, "zz should not change the cursor's line")
    }

    func testZbPlacesCursorLineAtBottom() {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: 20, column: 0), length: 0))
        keys("zb")
        XCTAssertEqual(line, 20, "zb should not change the cursor's line")
    }

    // MARK: - g0 / g$ / gj / gk (Display-Line Motions)

    func testGJMovesByDisplayLine() {
        // For non-wrapped lines, gj == j.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gj")
        XCTAssertEqual(line, 1, "gj on a non-wrapping line should behave like j")
    }

    func testGKMovesByDisplayLine() {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: 5, column: 0), length: 0))
        keys("gk")
        XCTAssertEqual(line, 4, "gk on a non-wrapping line should behave like k")
    }
}
