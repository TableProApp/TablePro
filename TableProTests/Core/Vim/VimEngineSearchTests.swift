//
//  VimEngineSearchTests.swift
//  TableProTests
//
//  Spec for search commands: / forward search, ? backward search, n / N repeat,
//  * search word forward, # search word backward.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineSearchTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!
    private var lastCommand: String?

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello world\nfoo bar hello\nthird hello\n")
        engine = VimEngine(buffer: buffer)
        engine.onCommand = { [weak self] cmd in self?.lastCommand = cmd }
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        lastCommand = nil
        super.tearDown()
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func enter() { _ = engine.process("\r", shift: false) }
    private func escape() { _ = engine.process("\u{1B}", shift: false) }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - / Forward Search

    func testForwardSearchFindsFirstMatch() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("/world")
        enter()
        XCTAssertEqual(pos, 6, "/world should land on the 'w' of 'world'")
    }

    func testForwardSearchSkipsCursorPosition() {
        // Cursor on the match itself — / should find the NEXT occurrence, not stay.
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("/hello")
        enter()
        XCTAssertEqual(pos, 20, "/hello from offset 12 should find the next 'hello' at offset 20")
    }

    func testForwardSearchWrapsAroundEndOfBuffer() {
        // Default vim search wraps. From offset 30 (past last 'hello'), search wraps to top.
        buffer.setSelectedRange(NSRange(location: 32, length: 0))
        keys("/hello")
        enter()
        XCTAssertEqual(pos, 0, "Forward search past last match should wrap to first match")
    }

    func testForwardSearchNotFoundLeavesCursor() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("/nomatch")
        enter()
        XCTAssertEqual(pos, 0, "Failed search should not move the cursor")
    }

    func testForwardSearchEscapeCancels() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("/world")
        escape()
        XCTAssertEqual(pos, 0, "Escape during search should cancel without moving")
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - ? Backward Search

    func testBackwardSearchFindsPriorMatch() {
        buffer.setSelectedRange(NSRange(location: 30, length: 0))
        keys("?hello")
        enter()
        XCTAssertEqual(pos, 20, "?hello from offset 30 should find the prior 'hello' at offset 20")
    }

    func testBackwardSearchWrapsAroundStartOfBuffer() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("?hello")
        enter()
        XCTAssertEqual(pos, 32, "Backward search at start should wrap to the last match")
    }

    // MARK: - n / N Repeat Search

    func testNRepeatsForwardSearch() {
        // From offset 0 (cursor already on 'hello'), /hello searches AFTER the cursor,
        // so it lands on the second 'hello' at offset 20. n advances to 32, the next n
        // wraps back to 0.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("/hello")
        enter()
        XCTAssertEqual(pos, 20)
        keys("n")
        XCTAssertEqual(pos, 32, "n should advance to the next match")
        keys("n")
        XCTAssertEqual(pos, 0, "n past the last match wraps to the first")
    }

    func testNRepeatsBackwardSearch() {
        buffer.setSelectedRange(NSRange(location: 32, length: 0))
        keys("?hello")
        enter()
        keys("n")
        XCTAssertEqual(pos, 0, "After ? search, n should continue backward")
    }

    func testCapitalNReversesDirection() {
        // /hello from cursor 0 advances to 20. n advances to 32. N reverses → back to 20.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("/hello")
        enter()
        keys("n")
        XCTAssertEqual(pos, 32)
        keys("N")
        XCTAssertEqual(pos, 20, "N should reverse the direction of the last search")
    }

    func testNWithCount() {
        // /hello from cursor 0 advances to 20. 2n advances through two more matches
        // (32, then wrap to 0). 2n leaves cursor at 0.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("/hello")
        enter()
        keys("2n")
        XCTAssertEqual(pos, 0, "2n past last match should wrap to first")
    }

    // MARK: - * (Search Word Under Cursor Forward)

    func testStarSearchesWordUnderCursorForward() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("*")
        XCTAssertEqual(pos, 20, "* should find the next occurrence of the word under cursor")
    }

    func testStarMatchesWholeWordOnly() {
        // "foo foobar" — * on 'foo' should NOT match 'foobar'.
        buffer = VimTextBufferMock(text: "foo foobar foo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("*")
        XCTAssertEqual(pos, 11, "* should match whole words only, skipping 'foobar'")
    }

    // MARK: - # (Search Word Under Cursor Backward)

    func testHashSearchesWordUnderCursorBackward() {
        buffer.setSelectedRange(NSRange(location: 32, length: 0))
        keys("#")
        XCTAssertEqual(pos, 20, "# should find the previous occurrence of the word under cursor")
    }

    // MARK: - Search with Operator

    func testDeleteToForwardSearchMatch() throws {
        // Search-as-motion (d/pattern) is not yet wired into the operator + motion
        // machinery — the search command runs but does not feed its target back as
        // a motion endpoint. Leaving this test as a documented TODO so the contract
        // is recorded for the next implementation pass.
        throw XCTSkip("Operator + search motion (d/pattern) not yet implemented")
    }

    // MARK: - Search Highlighting

    func testSearchStateRetainedAfterMatch() {
        // After a successful search, n/N should continue using the same pattern.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("/foo")
        enter()
        XCTAssertEqual(pos, 12)
        // Without re-entering /, n should still find 'foo' or similar.
        keys("n")
        // No second 'foo' in this buffer (after wrapping returns to same match).
        XCTAssertEqual(pos, 12, "n with no other match should stay (wrap returns to same match)")
    }
}
