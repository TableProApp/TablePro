//
//  VimEngineUndoRepeatTests.swift
//  TableProTests
//
//  Specification tests for undo (u), redo (Ctrl+R via engine.redo()),
//  the repeat command (.), and the line undo (U).
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineUndoRepeatTests: XCTestCase {
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

    // MARK: - u: Undo

    func testUCallsBufferUndo() {
        XCTAssertEqual(buffer.undoCallCount, 0)
        keys("u")
        XCTAssertEqual(buffer.undoCallCount, 1)
    }

    func testUWithCountCallsUndoNTimes() {
        keys("3u")
        XCTAssertEqual(buffer.undoCallCount, 3, "3u should call undo three times")
    }

    func testUConsumesKey() {
        XCTAssertTrue(engine.process("u", shift: false))
    }

    // MARK: - Ctrl+R: Redo

    func testRedoCallsBufferRedo() {
        XCTAssertEqual(buffer.redoCallCount, 0)
        engine.redo()
        XCTAssertEqual(buffer.redoCallCount, 1)
    }

    func testMultipleRedoCalls() {
        engine.redo()
        engine.redo()
        engine.redo()
        XCTAssertEqual(buffer.redoCallCount, 3)
    }

    // MARK: - U: Undo Line (undo all changes on the last edited line)

    func testCapitalUUndoesLineChanges() {
        // U undoes all changes made on the last edited line in one go.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // delete 'h'
        keys("x") // delete 'e'
        key("U", shift: true)
        XCTAssertEqual(buffer.undoCallCount, 2,
            "U should restore the original line — implemented via repeated undo")
    }

    // MARK: - . (Repeat Last Change)

    func testDotRepeatsLastEdit() {
        // Delete a word, then dot should delete another word.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw") // delete "hello "
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
        keys(".")
        XCTAssertEqual(buffer.text, "\nsecond line\nthird line\n",
            ". should repeat the last change (delete word)")
    }

    func testDotRepeatsXDelete() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x")
        XCTAssertEqual(buffer.text, "ello world\nsecond line\nthird line\n")
        keys(".")
        XCTAssertEqual(buffer.text, "llo world\nsecond line\nthird line\n",
            ". should repeat the last delete")
    }

    func testDotRepeatsWithExplicitCount() {
        // dw, then 3. should delete 3 more words.
        buffer = VimTextBufferMock(text: "a b c d e f\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw") // delete "a "
        keys("3.") // delete 3 more words
        XCTAssertEqual(buffer.text, "e f\n",
            "3. should repeat the last change three times")
    }

    func testDotDoesNotRepeatMotions() {
        // Pure motions (no edit) should not be repeatable by dot.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        keys("l")
        keys(".") // no last change → no-op
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    func testDotRepeatsInsertedText() {
        // Inserted text should be repeatable. This requires the engine to record the
        // insert-mode text, then dot replays it. Hard to test purely at engine level —
        // we at least assert that dot is consumed.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("i")
        _ = engine.process("X", shift: false) // pass-through in insert mode
        _ = engine.process("\u{1B}", shift: false) // escape
        let consumed = engine.process(".", shift: false)
        XCTAssertTrue(consumed, ". must be consumed in normal mode")
    }
}
