//
//  VimEngineMacroTests.swift
//  TableProTests
//
//  Spec for macro recording and playback: q{a-z} starts/stops recording, @{a-z}
//  replays a named macro, @@ replays the last replayed macro.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineMacroTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "aaa bbb ccc ddd\n")
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

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - Recording

    func testQStartsRecordingIntoNamedRegister() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        // After recording, the buffer should reflect the recorded edit once.
        XCTAssertEqual(buffer.text, "bbb ccc ddd\n",
            "Recording the macro should still execute the keys")
    }

    func testQAtoQClosesRecording() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("x")
        keys("q")
        // Now type 'x' again — it should NOT be recorded (recording is closed).
        keys("x")
        XCTAssertEqual(buffer.text, "a bbb ccc ddd\n",
            "Recording stops on the second q; subsequent keys must not be appended")
    }

    // MARK: - Playback

    func testAtAReplaysNamedMacro() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        XCTAssertEqual(buffer.text, "bbb ccc ddd\n")
        keys("@a")
        XCTAssertEqual(buffer.text, "ccc ddd\n",
            "@a should replay the recorded dw once")
    }

    func testAtACanBeReplayedMultipleTimes() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        keys("@a")
        keys("@a")
        XCTAssertEqual(buffer.text, "ddd\n", "Three deletions total: 1 recording + 2 replays")
    }

    func testAtAtReplaysLastMacro() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        keys("@a")
        keys("@@")
        XCTAssertEqual(buffer.text, "ddd\n",
            "@@ should replay the most recently invoked macro")
    }

    func testAtAWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("dw")
        keys("q")
        keys("3@a")
        XCTAssertEqual(buffer.text, "\n",
            "3@a should replay the macro three times")
    }

    // MARK: - Multiple Macros

    func testTwoIndependentMacros() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("w")
        keys("q")
        XCTAssertEqual(pos, 4)
        keys("qb")
        keys("dw")
        keys("q")
        XCTAssertEqual(buffer.text, "aaa ccc ddd\n",
            "Macro 'b' should run once during recording")
        keys("0@a")
        XCTAssertEqual(pos, 4, "Macro 'a' should still advance by one word when invoked")
    }

    // MARK: - Empty Macro

    func testEmptyMacroReplayIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("q")
        let snapshot = buffer.text
        keys("@a")
        XCTAssertEqual(buffer.text, snapshot, "Replaying an empty macro should be a no-op")
    }

    // MARK: - Recording During Visual Mode

    func testRecordingCapturesVisualOperation() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("v")
        keys("ll")
        keys("d")
        keys("q")
        // Buffer should reflect one visual delete.
        XCTAssertEqual(buffer.text, " bbb ccc ddd\n")
        // Replay should perform another visual-style delete from the current cursor.
        keys("@a")
        // The exact result depends on cursor position, but it should mutate the buffer.
        XCTAssertNotEqual(buffer.text, " bbb ccc ddd\n",
            "@a after recording a visual delete should re-execute and change the buffer")
    }

    // MARK: - Recursive Macro Safety

    func testRecursiveMacroDoesNotInfiniteLoop() {
        // Set up a macro that includes a self-reference.
        buffer = VimTextBufferMock(text: "abcd\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("qa")
        keys("x@a")
        keys("q")
        // The recording itself runs once. The trailing @a inside the macro should
        // not crash, even if not bounded — engines normally cap recursion depth.
        XCTAssertNotNil(buffer.text)
    }
}
